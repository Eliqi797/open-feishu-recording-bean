import hashlib
import json
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from bean.core import Store, Problem
from bean.live import LiveStore


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.tmp.name), reserve_bytes=0)
        self.live = LiveStore(self.store)
        self.meta = {'device_id': 'd3200', 'source_id': 'recording', 'title': 'Test'}
        self.sid = self.live.begin(self.meta)['session_id']
        self.audio = b'OggS' + bytes(160)
        self.sha = hashlib.sha256(self.audio).hexdigest()

    def tearDown(self):
        self.tmp.cleanup()

    def put(self, idx=0, duration=20000):
        return self.live.put(self.sid, idx, self.audio, self.sha, duration)

    def test_resume_deduplicates_and_rejects_gap_conflict_short_middle(self):
        self.assertEqual(self.live.begin(self.meta)['session_id'], self.sid)
        self.assertTrue(self.put()['verified'])
        self.assertTrue(self.put()['verified'])
        with self.assertRaisesRegex(Problem, 'CONFLICT'):
            self.put(duration=1000)
        with self.assertRaisesRegex(Problem, 'GAP'):
            self.put(2)
        self.put(1, 1000)
        with self.assertRaisesRegex(Problem, 'SHORT_SEGMENT'):
            self.put(2)
        self.assertEqual(self.live.status(self.sid)['received_ms'], 21000)

    def test_late_join_offset_is_preserved_and_capture_metadata_is_immutable(self):
        meta = {**self.meta, 'source_id': 'capture-2', 'original_source_id': 'recording', 'start_ms': 1939440}
        sid = self.live.begin(meta)['session_id']
        self.live.put(sid, 0, self.audio, self.sha, 20000)
        self.live.put(sid, 1, self.audio, self.sha, 20000)
        state = self.live.status(sid)
        self.assertEqual([x['start_ms'] for x in state['segments']], [1939440, 1959440])
        self.assertEqual(state['received_ms'], 40000)
        for altered in [{**meta, 'start_ms': 0}, {**meta, 'original_source_id': 'different'}]:
            with self.assertRaisesRegex(Problem, 'CONFLICT'):
                self.live.begin(altered)

    def test_short_windows_keep_offsets_retry_and_tail_rules(self):
        for window in (2000,5000,10000):
            meta={**self.meta,'source_id':str(window),'window_ms':window,'start_ms':12000}
            sid=self.live.begin(meta)['session_id']
            for i in range(2):
                self.assertTrue(self.live.put(sid,i,self.audio,self.sha,window)['verified'])
            self.assertTrue(self.live.put(sid,1,self.audio,self.sha,window)['verified'])
            self.live.put(sid,2,self.audio,self.sha,500)
            status=self.live.status(sid)
            self.assertEqual([s['start_ms'] for s in status['segments']],[12000,12000+window,12000+window*2])
            self.assertEqual(status['received_ms'],window*2+500)
            with self.assertRaisesRegex(Problem,'SHORT_SEGMENT'):
                self.live.put(sid,3,self.audio,self.sha,window)
            with self.assertRaisesRegex(Problem,'METADATA_CONFLICT'):
                self.live.begin({**meta,'window_ms':20000})
            with self.assertRaisesRegex(Problem,'TOO_LONG'):
                self.live.put(sid,3,self.audio,self.sha,20000)
        with self.assertRaises(Problem):self.live.begin({**self.meta,'window_ms':1000})
        self.assertEqual(self.live.session(self.sid)['window_ms'],20000)

    def test_corruption_or_wrong_hash_never_has_verified_receipt(self):
        with self.assertRaisesRegex(Problem, 'CHECKSUM'):
            self.live.put(self.sid, 0, self.audio, '0' * 64, 20000)
        self.put()
        (self.live.root / self.sid / '0.ogg').write_bytes(b'broken')
        with self.assertRaisesRegex(Problem, 'CORRUPT'):
            self.put()

    def test_finish_requires_device_end_and_verified_matching_full_recording(self):
        self.put()
        with self.assertRaisesRegex(Problem, 'DEVICE_END_REQUIRED'):
            self.live.finish(self.sid, {})
        s = self.store.initiate({**self.meta, 'size': len(self.audio), 'sha256': self.sha, 'mime': 'audio/ogg'})
        body = {'device_end_observed': True, 'recording_id': s['recording_id'], 'segment_count': 1}
        with self.assertRaisesRegex(Problem, 'MISMATCH'):
            self.live.finish(self.sid, body)
        self.store.put_chunk(s['upload_id'], 0, self.audio, self.sha)
        self.store.complete(s['upload_id'])
        with self.assertRaisesRegex(Problem, 'COUNT_MISMATCH'):
            self.live.finish(self.sid, {**body, 'segment_count': 2})
        self.assertEqual(self.live.finish(self.sid, body)['status'], 'completed')
        self.assertEqual(self.live.finish(self.sid, body)['recording_id'], s['recording_id'])
        with self.assertRaisesRegex(Problem, 'CLOSED'):
            self.put(1)

    def test_live_worker_preserves_raw_provenance_and_separate_speaker_scope(self):
        self.put()
        result = {'text': '测试', 'segments': [{'text': '测试', 'words': [{'speaker_id': 'speaker_0', 'start_ms': 0, 'end_ms': 100}]}], 'metrics': {'audio_seconds': 20}}
        with patch('bean.live.transcribe', return_value=result):
            self.assertTrue(self.live.once())
        status = self.live.status(self.sid)
        self.assertEqual(status['text'], '测试')
        self.assertTrue(status['provisional'])
        saved = json.loads((self.live.root / self.sid / '0.json').read_text())
        self.assertEqual(saved['segments'][0]['words'][0]['speaker_id'], 'window_0:speaker_0')
        self.assertFalse(self.live.once())

    def test_restart_recovers_inflight_and_silence_does_not_invent_text(self):
        self.put()
        with self.store.db() as db:
            db.execute("UPDATE live_segments SET status='running'")
        resumed = LiveStore(self.store)
        with patch('bean.live.transcribe', side_effect=Problem('ASR_NO_FINAL_TRANSCRIPT', 422)):
            self.assertTrue(resumed.once())
        state = resumed.status(self.sid)
        self.assertEqual(state['text'], '')
        self.assertEqual(state['segments'][0]['status'], 'no_speech')

    def test_live_processing_continues_while_archive_worker_is_busy(self):
        from bean.worker import Worker
        worker=Worker(self.store);archive_started=threading.Event();release=threading.Event();caption_done=threading.Event()
        def slow_archive():
            archive_started.set();release.wait(3);return False
        def caption():
            if archive_started.wait(2):caption_done.set()
            return False
        worker.once=slow_archive;worker.live.once=caption
        try:
            worker.start()
            self.assertTrue(caption_done.wait(2))
            self.assertFalse(release.is_set())
        finally:
            worker.stop.set();release.set();worker.thread.join(3);worker.live_thread.join(3)

    def test_failed_window_can_retry_without_reupload(self):
        self.put()
        with patch('bean.live.transcribe', side_effect=Problem('NVIDIA_UNAVAILABLE', 502)):
            self.live.once()
        self.assertEqual(self.live.status(self.sid)['segments'][0]['status'], 'failed')
        self.assertEqual(self.live.retry(self.sid, 0)['segments'][0]['status'], 'queued')


if __name__ == '__main__':
    unittest.main()
