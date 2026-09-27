import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from bean.core import Problem, Store
from bean.feishu import publish, render, reconcile_document
from bean.providers import normalize_riva, llm_once


class NormalizeTests(unittest.TestCase):
    def test_missing_fields_are_not_invented(self):
        value = normalize_riva([{"results": [{"is_final": True, "alternatives": [{"transcript": "你好", "words": [{"word": "你好"}]}]}]}])
        word = value["segments"][0]["words"][0]
        self.assertIsNone(word["start_ms"])
        self.assertIsNone(word["speaker_id"])
        self.assertFalse(value["speaker_tags_observed"])

    def test_ignore_interim_and_scope_speakers_to_session(self):
        value = normalize_riva([{"results": [{"is_final": False, "alternatives": [{"transcript": "草稿"}]},
                                              {"is_final": True, "alternatives": [{"transcript": "最终", "words": [{"word": "最终", "start_time": "123", "end_time": "500", "speaker_tag": 1}]}]}]}])
        self.assertEqual(value["text"], "最终")
        self.assertEqual(value["segments"][0]["words"][0]["speaker_id"], "session-0:speaker-1")
        self.assertEqual(value["segments"][0]["start_ms"], 123)

    def test_no_final_is_not_success(self):
        with self.assertRaisesRegex(Problem, "ASR_NO_FINAL_TRANSCRIPT"):
            normalize_riva([])

    def test_whisper_offline_does_not_require_streaming_final_flag(self):
        value = normalize_riva([{"results": [{"alternatives": [{"transcript": "离线对照"}]}]}], offline=True, source="nvidia-whisper-large-v3")
        self.assertEqual(value["text"], "离线对照")
        self.assertEqual(value["source"], "nvidia-whisper-large-v3")

    def test_invalid_summary_rejected(self):
        with patch.dict(os.environ, {"LLM_BASE_URL": "https://example.com/v1", "LLM_MODEL": "test", "LLM_API_KEY": "test"}), patch("bean.providers.request_json", return_value={"choices": [{"message": {"content": '{}'}}]}):
            with self.assertRaisesRegex(Problem, "LLM_INVALID_SUMMARY"):
                llm_once("test")


class FakeFeishu:
    def __init__(self):
        self.docs = {}
        self.creates = 0
        self.writes = 0
        self.lose_create = False
        self.lose_write = False

    def verify_identity(self):
        pass

    def create(self, title):
        self.creates += 1
        doc = "doc" + str(self.creates)
        self.docs[doc] = ""
        if self.lose_create:
            raise Problem("NETWORK_ERROR", 502)
        return doc

    def content(self, doc):
        return self.docs[doc]

    def append(self, doc, text):
        self.writes += 1
        self.docs[doc] += text
        if self.lose_write:
            self.lose_write = False
            raise Problem("NETWORK_ERROR", 502)


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name), reserve_bytes=0)
        import hashlib
        s = self.store.initiate({"device_id": "d", "source_id": "s", "title": "会议", "size": 1, "sha256": hashlib.sha256(b"x").hexdigest()})
        self.rid = s["recording_id"]
        self.store.save_result(self.rid, "asr", {"segments": [{"id": 0, "text": "测试内容"}]})
        self.store.save_result(self.rid, "summary", {"summary": "测试摘要", "decisions": [], "actions": [], "uncertainties": []})
        self.env = patch.dict(os.environ, {"PUBLIC_ORIGIN": "https://example.com"})
        self.env.start()
        self.client = FakeFeishu()

    def tearDown(self):
        self.env.stop()
        self.temp.cleanup()

    def test_repeat_publish_does_not_duplicate(self):
        result = publish(self.store, self.rid, self.client)
        self.assertTrue(result["api_readback_verified"])
        self.assertFalse(result["human_visibility_verified"])
        publish(self.store, self.rid, self.client)
        self.assertEqual(self.client.creates, 1)
        self.assertEqual(self.client.writes, 1)

    def test_lost_create_response_requires_reconciliation(self):
        self.client.lose_create = True
        with self.assertRaises(Problem):
            publish(self.store, self.rid, self.client)
        self.client.lose_create = False
        with self.assertRaisesRegex(Problem, "FEISHU_CREATE_UNCERTAIN"):
            publish(self.store, self.rid, self.client)
        self.assertEqual(self.client.creates, 1)

    def test_lost_write_response_recovers_by_readback(self):
        self.client.lose_write = True
        with self.assertRaises(Problem):
            publish(self.store, self.rid, self.client)
        publish(self.store, self.rid, self.client)
        self.assertEqual(self.client.creates, 1)
        self.assertEqual(self.client.writes, 1)

    def test_external_content_change_does_not_append_again(self):
        publish(self.store, self.rid, self.client)
        self.client.docs["doc1"] = "用户改过内容"
        with self.assertRaisesRegex(Problem, "FEISHU_WRITE_UNCERTAIN"):
            publish(self.store, self.rid, self.client)
        self.assertEqual(self.client.writes, 1)

    def test_long_transcript_all_text_retained_and_linked(self):
        text='长文验收数据。'*5000
        transcript={'segments':[{'id':0,'text':text}]}
        summary={'summary':'测试','decisions':[],'actions':[],'uncertainties':[]}
        parts=render(self.store.recording(self.rid),transcript,summary)
        self.assertGreater(len(parts),2)
        self.assertIn(text,''.join(body for _,body in parts))
        self.store.save_result(self.rid,'asr',transcript)
        result=publish(self.store,self.rid,self.client)
        self.assertEqual(len(result['documents']),len(parts))
        self.assertIn('关联文档',self.client.docs['doc1'])
        before=self.client.writes;publish(self.store,self.rid,self.client)
        self.assertEqual(self.client.writes,before)

    def test_reconcile_rejects_foreign_or_nonempty_document(self):
        self.client.lose_create=True
        with self.assertRaises(Problem):publish(self.store,self.rid,self.client)
        self.client.title=lambda doc:'wrong'
        with self.assertRaisesRegex(Problem,'TITLE_MISMATCH'):reconcile_document(self.store,self.rid,0,'existingdoc',self.client)
        row=self.store.recording(self.rid)['publications'][0]
        self.client.title=lambda doc:row['title']
        self.client.docs['existingdoc']='user content'
        with self.assertRaisesRegex(Problem,'NOT_EMPTY'):reconcile_document(self.store,self.rid,0,'existingdoc',self.client)
        self.client.docs['existingdoc']=''
        reconcile_document(self.store,self.rid,0,'existingdoc',self.client)
        self.client.lose_create=False;publish(self.store,self.rid,self.client)
        self.assertEqual(self.client.creates,1)

    def test_partial_write_can_resume_exact_prefix_without_duplicate(self):
        original=self.client.append
        def partial(doc,text):
            self.client.writes+=1;self.client.docs[doc]+=text[:100]
            raise Problem('NETWORK_ERROR',502)
        self.client.append=partial
        with self.assertRaises(Problem):publish(self.store,self.rid,self.client)
        prefix=self.client.docs['doc1'];self.client.append=original
        publish(self.store,self.rid,self.client)
        self.assertEqual(self.client.docs['doc1'].count(prefix),1)
        self.assertEqual(self.client.creates,1)

    def test_partial_write_with_external_edit_stops(self):
        self.client.lose_write=True
        with self.assertRaises(Problem):publish(self.store,self.rid,self.client)
        self.client.docs['doc1']='用户编辑'+self.client.docs['doc1'][:30]
        with self.assertRaisesRegex(Problem,'FEISHU_WRITE_UNCERTAIN'):publish(self.store,self.rid,self.client)
        self.assertEqual(self.client.writes,1)


if __name__ == "__main__":
    unittest.main()
