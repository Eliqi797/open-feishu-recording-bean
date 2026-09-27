import json
import tempfile
import unittest
import wave
from pathlib import Path
from bean.core import Problem
from bean.pipeline import transcribe_resumable, summarize_resumable, review_actions
from bean.providers import normalize_riva

class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
    def tearDown(self):
        self.tmp.cleanup()
    def test_chunk_retry_reuses_success_and_offsets_speakers(self):
        path = self.root / 'audio.wav'
        with wave.open(str(path), 'wb') as f:
            f.setparams((1, 2, 16000, 0, 'NONE', '')); f.writeframes(b'\1\0' * 16000 * 3)
        calls = []
        def recognize(audio, raw, **kw):
            i = int(audio.stem.split('-')[1]); calls.append(i)
            if calls == [0, 1]: raise Problem('NVIDIA_UNAVAILABLE')
            raw.write_text('{}')
            return {'segments': [{'id': 0, 'text': 'hello', 'start_ms': 0, 'end_ms': 500, 'speaker_id': None,
                                  'words': [{'text': 'hello', 'start_ms': 0, 'end_ms': 500, 'speaker_id': 'session-0:speaker-1'}]}]}
        with self.assertRaises(Problem): transcribe_resumable(path, self.root / 'work', chunk_seconds=1, recognizer=recognize)
        result = transcribe_resumable(path, self.root / 'work', chunk_seconds=1, recognizer=recognize)
        self.assertEqual(calls, [0, 1, 1, 2])
        self.assertEqual([s['start_ms'] for s in result['segments']], [0, 1000, 2000])
        self.assertEqual(len({s['words'][0]['speaker_id'] for s in result['segments']}), 3)
        self.assertFalse(list((self.root / 'work').glob('*.wav')))
    def test_summary_checkpoints_retain_raw_and_reject_inventions(self):
        transcript = {'segments': [{'id': 0, 'text': '小王核对合同。'}]}
        calls = []
        def summarize(text, raw_path):
            calls.append(text); raw_path.write_text('{"original":true}')
            return {'summary': '核对合同', 'decisions': [], 'uncertainties': [], 'actions': [
                {'task': '核对合同', 'owner': '小李', 'due_date': '明天', 'evidence': '小王核对合同。'},
                {'task': '付款', 'owner': None, 'due_date': None, 'evidence': '虚构内容'}]}
        out = summarize_resumable(transcript, self.root, summarizer=summarize)
        self.assertIsNone(out['actions'][0]['owner']); self.assertIsNone(out['actions'][0]['due_date'])
        self.assertEqual(len(out['rejected_actions']), 1)
        self.assertEqual(summarize_resumable(transcript, self.root, summarizer=summarize), out)
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(list(self.root.glob('*-raw-*.json'))), 1)
        transcript['segments'][0]['text'] += '已完成。'
        summarize_resumable(transcript, self.root, summarizer=summarize)
        self.assertEqual(len(calls), 2)
    def test_zero_speaker_requires_positive_tag_and_explicit_policy(self):
        raw = [{'results': [{'is_final': True, 'alternatives': [{'transcript': 'ab', 'words': [{'word': 'a', 'speaker_tag': 0}, {'word': 'b', 'speaker_tag': 1}]}]}]}]
        self.assertIsNone(normalize_riva(raw)['segments'][0]['words'][0]['speaker_id'])
        self.assertEqual(normalize_riva(raw, speaker_zero_policy='zero_based')['segments'][0]['words'][0]['speaker_id'], 'session-0:speaker-0')
        raw[0]['results'][0]['alternatives'][0]['words'].pop()
        self.assertIsNone(normalize_riva(raw, speaker_zero_policy='zero_based')['segments'][0]['words'][0]['speaker_id'])
    def test_silence_not_fake_transcript(self):
        path = self.root / 'silent.wav'
        with wave.open(str(path), 'wb') as f:
            f.setparams((1, 2, 16000, 0, 'NONE', '')); f.writeframes(b'\0' * 32000)
        with self.assertRaisesRegex(Problem, 'ASR_NO_SPEECH'):
            transcribe_resumable(path, self.root / 'work')

    def test_long_summary_retry_preserves_completed_parts_and_full_actions(self):
        transcript={'segments':[{'id':i,'text':f'第{i}段核对。'*30} for i in range(12)]}
        calls=[]
        def summarize(text,raw_path):
            calls.append(text)
            if len(calls)==2:raise Problem('PROVIDER_NETWORK_FAILURE')
            raw_path.write_text('{}')
            return {'summary':'合并摘要','decisions':[],'actions':[],'uncertainties':[]}
        with self.assertRaises(Problem):summarize_resumable(transcript,self.root,summarizer=summarize,chunk_chars=200)
        first=calls[0]
        result=summarize_resumable(transcript,self.root,summarizer=summarize,chunk_chars=200)
        self.assertEqual(calls.count(first),1)
        self.assertGreater(len(result['parts']),5)
        before=len(calls)
        summarize_resumable(transcript,self.root,summarizer=summarize,chunk_chars=200)
        self.assertEqual(len(calls),before)

    def test_unrecognized_chunk_does_not_discard_later_speech_or_claim_silence(self):
        path = self.root / 'audio.wav'
        with wave.open(str(path), 'wb') as f:
            f.setparams((1, 2, 16000, 0, 'NONE', '')); f.writeframes(b'\1\0' * 16000 * 3)
        calls = []
        def recognize(audio, raw, **kw):
            idx = int(audio.stem.split('-')[1]); calls.append(idx)
            if idx == 0: raise Problem('ASR_NO_FINAL_TRANSCRIPT', 422)
            return {'segments': [{'id': 0, 'text': '后面有发言', 'words': [], 'start_ms': 0, 'end_ms': 800}]}
        result = transcribe_resumable(path, self.root / 'work', chunk_seconds=1, recognizer=recognize)
        self.assertEqual(calls, [0, 1, 2])
        self.assertEqual(result['coverage']['status'], 'partial')
        gap = result['coverage']['unrecognized_chunks'][0]
        self.assertFalse(gap['digital_silence']); self.assertEqual((gap['start_ms'], gap['end_ms']), (0, 1000))
        self.assertEqual([s['start_ms'] for s in result['segments']], [1000, 2000])
        transcribe_resumable(path, self.root / 'work', chunk_seconds=1, recognizer=recognize)
        self.assertEqual(calls, [0, 1, 2, 0])

    def test_all_unrecognized_is_not_reported_as_confirmed_silence(self):
        path = self.root / 'audio.wav'
        with wave.open(str(path), 'wb') as f:
            f.setparams((1, 2, 16000, 0, 'NONE', '')); f.writeframes(b'\1\0' * 16000 * 2)
        calls = []
        def recognize(audio, raw, **kw):
            calls.append(audio.name); raise Problem('ASR_NO_FINAL_TRANSCRIPT', 422)
        with self.assertRaisesRegex(Problem, 'ASR_NO_FINAL_TRANSCRIPT'):
            transcribe_resumable(path, self.root / 'work', chunk_seconds=1, recognizer=recognize)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(json.loads((self.root / 'work' / 'coverage.json').read_text())['unrecognized_chunks']), 2)

    def test_missing_audio_ranges_survive_summary_and_feishu_render(self):
        from bean.feishu import render
        from unittest.mock import patch
        transcript = {'segments': [{'id': 0, 'text': '有发言', 'words': []}],
                      'coverage': {'unrecognized_chunks': [{'start_ms': 0, 'end_ms': 120000}]}}
        def summarize(text, raw_path):
            return {'summary': '有发言', 'decisions': [], 'actions': [], 'uncertainties': []}
        summary = summarize_resumable(transcript, self.root / 'summary', summarizer=summarize)
        self.assertIn('0–120 秒', summary['uncertainties'][0])
        with patch.dict('os.environ', {'PUBLIC_ORIGIN': 'https://example.com'}):
            rendered = render({'id': 'a' * 32, 'title': '录音'}, transcript, summary)
        self.assertIn('转写不完整', rendered[0][1]); self.assertIn('00:00:00–00:02:00', rendered[0][1])
