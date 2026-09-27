import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from bean.core import Problem, Store
from bean.worker import Worker
from scripts.backup import backup, restore, verify


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = Store(self.root / "data", reserve_bytes=0)
        self.store.chunk_size = 4

    def tearDown(self):
        self.temp.cleanup()

    def begin(self, payload=b"abcdefghij", sha=None):
        return self.store.initiate({"device_id": "D3200-test", "source_id": "file-1", "title": "测试", "size": len(payload), "sha256": sha or hashlib.sha256(payload).hexdigest(), "mime": "audio/wav"})

    def send(self, s, payload=b"abcdefghij"):
        for i in range(0, len(payload), 4):
            part = payload[i:i+4]
            self.store.put_chunk(s["upload_id"], i//4, part, hashlib.sha256(part).hexdigest())

    def test_restart_resume_and_verified_receipt(self):
        s = self.begin()
        self.store.put_chunk(s["upload_id"], 0, b"abcd", hashlib.sha256(b"abcd").hexdigest())
        self.store = Store(self.root / "data", reserve_bytes=0)
        self.store.chunk_size = 4
        again = self.begin()
        self.assertEqual(s["upload_id"], again["upload_id"])
        self.assertEqual(len(again["chunks"]), 1)
        self.send(again)
        receipt = self.store.complete(s["upload_id"])
        self.assertTrue(receipt["stored"] and receipt["verified"])
        self.assertEqual((self.store.root / "audio" / s["recording_id"]).read_bytes(), b"abcdefghij")
        self.assertTrue(self.store.complete(s["upload_id"])["verified"])
        self.assertEqual(len(self.store.listing()), 1)

    def test_missing_chunk_cannot_complete(self):
        s = self.begin()
        with self.assertRaisesRegex(Problem, "MISSING_CHUNKS"):
            self.store.complete(s["upload_id"])
        self.assertFalse(self.store.recording(s["recording_id"])["stored"])

    def test_bad_chunk_never_persisted(self):
        s = self.begin()
        with self.assertRaisesRegex(Problem, "CHUNK_CHECKSUM_MISMATCH"):
            self.store.put_chunk(s["upload_id"], 0, b"abcd", "0"*64)
        self.assertEqual(self.store.upload_status(s["upload_id"])["chunks"], [])

    def test_full_hash_failure_keeps_retry_data(self):
        s = self.begin(sha="0"*64)
        self.send(s)
        with self.assertRaisesRegex(Problem, "FILE_CHECKSUM_MISMATCH"):
            self.store.complete(s["upload_id"])
        self.assertFalse(self.store.recording(s["recording_id"])["stored"])
        self.assertTrue((self.store.root / "uploads" / s["upload_id"] / "0").exists())

    def test_corrupt_durable_audio_not_reported_success(self):
        s = self.begin()
        self.send(s)
        self.store.complete(s["upload_id"])
        (self.store.root / "audio" / s["recording_id"]).write_bytes(b"bad")
        with self.assertRaisesRegex(Problem, "STORED_AUDIO_CORRUPT"):
            self.store.complete(s["upload_id"])

    def test_conflicting_chunk_does_not_replace_original(self):
        s = self.begin()
        self.store.put_chunk(s["upload_id"], 0, b"abcd", hashlib.sha256(b"abcd").hexdigest())
        with self.assertRaisesRegex(Problem, "CHUNK_CONFLICT"):
            self.store.put_chunk(s["upload_id"], 0, b"xxxx", hashlib.sha256(b"xxxx").hexdigest())
        self.assertEqual((self.store.root / "uploads" / s["upload_id"] / "0").read_bytes(), b"abcd")

    def test_disk_full_before_acceptance(self):
        self.store.reserve_bytes = 10**18
        with self.assertRaisesRegex(Problem, "INSUFFICIENT_STORAGE"):
            self.begin()
        self.assertEqual(self.store.listing(), [])

    def test_crashed_running_job_is_interrupted(self):
        s = self.begin()
        self.send(s)
        self.store.complete(s["upload_id"])
        self.store.set_job(s["recording_id"], "asr", "running")
        restarted = Store(self.store.root)
        job = next(j for j in restarted.recording(s["recording_id"])["jobs"] if j["stage"] == "asr")
        self.assertEqual(job["status"], "interrupted")

    def test_missing_provider_blocks_without_fake_result(self):
        s = self.begin()
        self.send(s)
        self.store.complete(s["upload_id"])
        self.store.enqueue(s["recording_id"], "asr")
        with patch("bean.worker.transcribe", side_effect=Problem("NVIDIA_RIVA_CLIENT_NOT_INSTALLED", 503)):
            self.assertTrue(Worker(self.store).once())
        r = self.store.recording(s["recording_id"])
        self.assertEqual(next(j for j in r["jobs"] if j["stage"] == "asr")["status"], "blocked")
        self.assertIsNone(self.store.result(r["id"], "asr"))
        with self.assertRaisesRegex(Problem, "PREVIOUS_STAGE_INCOMPLETE"):
            self.store.enqueue(r["id"], "summary")

    def test_unknown_speakers_preserve_transcript_and_allow_summary(self):
        s = self.begin(); self.send(s); self.store.complete(s['upload_id'])
        rid = s['recording_id']
        transcript = {'text': '实际文字', 'segments': [{'words': [{'text': '实际文字', 'speaker_id': None}]}]}
        self.store.save_result(rid, 'asr', transcript)
        self.store.set_job(rid, 'asr', 'completed')
        self.store.start_pipeline(rid)
        self.assertTrue(Worker(self.store).once())
        result = self.store.result(rid, 'diarization')
        self.assertEqual(result['capability_status'], 'unavailable')
        self.assertEqual(result['speaker_ids'], [])
        self.assertFalse(result['accuracy_verified'])
        self.assertFalse(result['sortformer_verified'])
        self.assertEqual(self.store.result(rid, 'asr'), transcript)
        self.assertEqual(next(j for j in self.store.recording(rid)['jobs'] if j['stage'] == 'summary')['status'], 'queued')

    def test_backup_restore_preserves_audio_and_pending_chunks(self):
        s = self.begin()
        self.send(s)
        self.store.complete(s["upload_id"])
        partial = self.begin(b"123456")
        self.store.put_chunk(partial["upload_id"], 0, b"1234", hashlib.sha256(b"1234").hexdigest())
        dest, restored = self.root / "backup", self.root / "restored"
        backup(self.store.root, dest)
        restore(dest, restored)
        self.assertEqual((restored / "audio" / s["recording_id"]).read_bytes(), b"abcdefghij")
        self.assertEqual((restored / "uploads" / partial["upload_id"] / "0").read_bytes(), b"1234")
        self.assertFalse(verify(restored)["independent_storage_verified"])
        (dest / "audio" / s["recording_id"]).write_bytes(b"tampered")
        with self.assertRaisesRegex(Problem, "BACKUP_CHECKSUM_MISMATCH"):
            verify(dest)

    def test_rate_limit_schedules_bounded_retry_without_reupload(self):
        s = self.begin()
        self.send(s)
        self.store.complete(s["upload_id"])
        self.store.enqueue(s["recording_id"], "asr")
        with patch("bean.worker.transcribe", side_effect=Problem("NVIDIA_RESOURCE_EXHAUSTED", 502)):
            worker = Worker(self.store)
            worker.once()
            job = next(j for j in self.store.recording(s["recording_id"])["jobs"] if j["stage"] == "asr")
            self.assertEqual(job["status"], "queued")
            self.assertGreater(job["retry_at"], 0)
            self.assertFalse(worker.once())
            for _ in range(2):
                with self.store.db() as db:
                    db.execute("UPDATE jobs SET retry_at=0 WHERE recording_id=?", (s["recording_id"],))
                worker.once()
        job = next(j for j in self.store.recording(s["recording_id"])["jobs"] if j["stage"] == "asr")
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["attempts"], 3)
        self.assertTrue(self.store.recording(s["recording_id"])["stored"])

    def test_simultaneous_duplicate_sessions_have_one_identity(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=4) as pool:
            sessions = list(pool.map(lambda _: self.begin(), range(8)))
        self.assertEqual(len({s["recording_id"] for s in sessions}), 1)

    def test_partial_chunk_corruption_is_detected_on_assembly(self):
        s = self.begin()
        self.send(s)
        (self.store.root / "uploads" / s["upload_id"] / "0").write_bytes(b"xxxx")
        with self.assertRaisesRegex(Problem, "CHUNK_CORRUPT"):
            self.store.complete(s["upload_id"])
        self.assertFalse(self.store.recording(s["recording_id"])["stored"])

    def test_auto_restart_pause_and_reference_provenance(self):
        session=self.begin();self.send(session);self.store.complete(session['upload_id']);rid=session['recording_id']
        self.store.start_pipeline(rid);self.store.set_job(rid,'asr','running')
        resumed=Store(self.store.root,reserve_bytes=0)
        self.assertEqual(resumed.recording(rid)['jobs'][0]['status'],'queued')
        resumed.pause_pipeline(rid)
        restarted=Store(self.store.root,reserve_bytes=0)
        self.assertEqual(restarted.recording(rid)['jobs'][0]['status'],'interrupted')
        restarted.import_reference(rid,'用户提供参考文字。')
        self.assertEqual(restarted.result(rid,'asr')['source'],'manual-reference-not-asr')
        self.assertFalse(restarted.result(rid,'diarization')['accuracy_verified'])
        restarted.start_pipeline(rid)
        self.assertEqual(restarted.recording(rid)['jobs'][2]['status'],'queued')

    def test_backup_rejects_unmanifested_files(self):
        session=self.begin();self.send(session);self.store.complete(session['upload_id'])
        dest=self.root/'backup';backup(self.store.root,dest)
        (dest/'extra').write_text('unexpected')
        with self.assertRaisesRegex(Problem,'BACKUP_FILE_SET_MISMATCH'):verify(dest)

    def test_restart_closes_stage_complete_enqueue_crash_window(self):
        session=self.begin();self.send(session);self.store.complete(session['upload_id']);rid=session['recording_id']
        self.store.start_pipeline(rid);self.store.set_job(rid,'asr','completed')
        restarted=Store(self.store.root,reserve_bytes=0)
        self.assertEqual(restarted.recording(rid)['jobs'][1]['status'],'queued')


if __name__ == "__main__":
    unittest.main()
