import json, os, stat, tempfile, unittest, wave
from pathlib import Path
from unittest.mock import patch, MagicMock
from bean.settings import Settings, scope, get, SECRETS, DEFAULTS
from bean.core import Problem
from bean.providers import transcribe, transcribe_compatible
from bean.feishu import Feishu

class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
        self.env=patch.dict(os.environ,{},clear=True);self.env.start();self.s=Settings(self.root)
    def tearDown(self):self.env.stop();self.tmp.cleanup()
    def test_redacted_preserve_clear_and_file_permissions(self):
        first=self.s.update({'revision':0,'values':{'NVIDIA_API_KEY':'private-test-secret'}})
        self.assertTrue(first['secrets_configured']['NVIDIA_API_KEY']);self.assertNotIn('private-test-secret',json.dumps(first))
        self.assertFalse(SECRETS & first['values'].keys())
        self.s.update({'revision':1,'values':{'NVIDIA_API_KEY':''}})
        self.assertEqual(self.s.snapshot()['NVIDIA_API_KEY'],'private-test-secret')
        self.assertEqual(stat.S_IMODE(self.s.path.stat().st_mode),0o600)
        self.s.update({'revision':2,'clear_secrets':['NVIDIA_API_KEY']})
        self.assertFalse(self.s.public()['secrets_configured']['NVIDIA_API_KEY'])
    def test_revision_conflict_does_not_replace_configuration(self):
        self.s.update({'revision':0,'values':{'LLM_MODEL':'first'}})
        with self.assertRaisesRegex(Problem,'CONFLICT'):self.s.update({'revision':0,'values':{'LLM_MODEL':'second'}})
        self.assertEqual(self.s.snapshot()['LLM_MODEL'],'first')
    def test_context_is_immutable_and_isolated_from_environ_and_other_deployment(self):
        self.s.update({'revision':0,'values':{'LLM_MODEL':'first'}})
        with scope(self.s.snapshot()):
            self.s.update({'revision':1,'values':{'LLM_MODEL':'second'}})
            self.assertEqual(get('LLM_MODEL'),'first')
            self.assertEqual(os.getenv('LLM_MODEL'),None)
        self.assertEqual(get('LLM_MODEL'),'')
        self.assertEqual(self.s.snapshot()['LLM_MODEL'],'second')
    def test_reject_bad_parameters_and_endpoint_key_reuse(self):
        for changes in [{'ASR_PROVIDER':'invented'},{'LLM_BASE_URL':'http://example.com'},{'LLM_BASE_URL':'https://name:secret@example.com'},{'FEISHU_DOCS_ORIGIN':'https://evil.example'},{'ASR_CHUNK_SECONDS':'0'}]:
            with self.assertRaises(Problem):self.s.update({'revision':0,'values':changes})
        with self.assertRaises(Problem):self.s.update({'revision':0,'clear_secrets':[{}]})
        self.s.update({'revision':0,'values':{'LLM_BASE_URL':'https://a.example/v1','LLM_API_KEY':'key-a'}})
        with self.assertRaisesRegex(Problem,'NEW_ENDPOINT'):self.s.update({'revision':1,'values':{'LLM_BASE_URL':'https://b.example/v1'}})
        self.s.update({'revision':1,'values':{'LLM_BASE_URL':'https://b.example/v1','LLM_API_KEY':'key-b'}})
        self.assertEqual(self.s.snapshot()['LLM_API_KEY'],'key-b')
    def test_compatible_asr_real_wav_multipart_missing_timestamps(self):
        source=self.root/'audio.wav';raw=self.root/'response.json'
        with wave.open(str(source),'wb') as f:f.setparams((1,2,16000,0,'NONE','not compressed'));f.writeframes(bytes(3200))
        opener=MagicMock();opener.open.return_value.__enter__.return_value.read.return_value=json.dumps({'text':'测试','segments':[{'text':'测试','start':-1,'end':None}]}).encode()
        with scope(dict(DEFAULTS,ASR_PROVIDER='openai_compatible',ASR_BASE_URL='https://asr.example/v1',ASR_API_KEY='key',ASR_MODEL='test-model')),patch('bean.providers.urllib.request.build_opener',return_value=opener):
            result=transcribe(source,raw)
        req=opener.open.call_args.args[0]
        self.assertEqual(req.full_url,'https://asr.example/v1/audio/transcriptions');self.assertIn(b'test-model',req.data);self.assertIn(b'RIFF',req.data)
        self.assertEqual(result['text'],'测试');self.assertIsNone(result['segments'][0]['start_ms']);self.assertIsNone(result['segments'][0]['speaker_id']);self.assertTrue(raw.exists());self.assertTrue(source.exists())
    def test_provider_selection_and_whisper_override(self):
        with scope(dict(DEFAULTS,ASR_PROVIDER='nvidia_whisper')),patch('bean.providers._transcribe_nim',return_value={}) as call:
            transcribe(Path('a'),Path('b'));self.assertTrue(call.call_args.args[-1])
    def test_feishu_app_explicit_confirmation_and_token_reuse(self):
        config=dict(DEFAULTS,FEISHU_AUTH_MODE='app',FEISHU_APP_ID='test-app',FEISHU_APP_SECRET='secret')
        with scope(config),patch('bean.feishu.request_json') as request:
            with self.assertRaisesRegex(Problem,'NOT_CONFIRMED'):Feishu().verify_identity()
            request.assert_not_called()
        with scope(dict(config,FEISHU_PERSONAL_CONFIRMED='1')),patch('bean.feishu.request_json',side_effect=[{'code':0,'tenant_access_token':'tenant-test'},{'code':0,'data':{'document':{'document_id':'doc'}}}]) as request:
            client=Feishu();client.verify_identity();self.assertEqual(client.create('test'),'doc')
            self.assertTrue(request.call_args_list[0].args[0].endswith('/auth/v3/tenant_access_token/internal'))
            self.assertEqual(request.call_args_list[1].args[1],'tenant-test');self.assertEqual(request.call_count,2)

class DocumentLayoutTests(unittest.TestCase):
    def test_recording_info_leads_and_real_heading_xml_retains_text(self):
        from bean.feishu import render,styled_xml
        with scope(dict(DEFAULTS,PUBLIC_ORIGIN='https://audio.example')):
            parts=render({'id':'a'*32,'title':'录音 1','size':1024,'recorded_at':1790310884},{'segments':[{'id':0,'start_ms':1000,'text':'正文 <保留>'}],'chunks':[{'end_ms':90000}]},{'title':'讨论项目排期并确认下一步','summary':'摘要','decisions':[],'actions':[],'uncertainties':[]})
        title,text=parts[0];self.assertEqual(title,'讨论项目排期并确认下一步');self.assertTrue(text.startswith('录音信息\n开始录制：2026-09-25 12:34:44'))
        self.assertIn('00:01:30',text);self.assertNotIn('待办事项',text);xml=styled_xml(text)
        self.assertIn('<h2>内容摘要</h2>',xml);self.assertIn('正文 &lt;保留&gt;',xml)
    def test_title_from_llm_is_validated(self):
        from bean.providers import title_once
        with scope(dict(DEFAULTS,LLM_BASE_URL='https://llm.example',LLM_MODEL='test',LLM_API_KEY='key')),patch('bean.providers.request_json',return_value={'choices':[{'message':{'content':'{"title":"讨论项目排期"}'}}]}):self.assertEqual(title_once('讨论排期'),'讨论项目排期')


class TodoLayoutTests(unittest.TestCase):
    def test_tasks_are_native_checkboxes_without_changing_readback_text(self):
        import xml.etree.ElementTree as ET
        from bean.feishu import styled_xml,compact,Feishu
        text='待办事项\n核对合同 <原件>\n责任人：待确认 · 日期：待确认\n依据：[1]\n\n确认交付时间\n责任人：王工 · 日期：明天（原话）\n依据：[2]\n\n待确认事项\n核实预算\n'
        root=ET.fromstring('<root>'+styled_xml(text)+'</root>')
        self.assertEqual([x.text for x in root.findall('checkbox')],['核对合同 <原件>','确认交付时间'])
        self.assertTrue(all(x.get('done')=='false' for x in root.findall('checkbox')))
        self.assertEqual(compact(''.join(root.itertext())),compact(text))
        client=Feishu();client.cli_mode=False;calls=[];client.call=lambda method,path,body:calls.append(body) or {}
        client.append('document',text)
        todos=[b for call in calls for b in call['children'] if b['block_type']==17]
        self.assertEqual(len(todos),2);self.assertEqual(todos[0]['todo']['style'],{'done':False})
        self.assertEqual(todos[0]['todo']['elements'][0]['text_run']['content'],'核对合同 <原件>')
    def test_no_actions_do_not_invent_checkboxes_and_long_task_stays_one(self):
        from bean.feishu import Feishu,styled_xml
        self.assertNotIn('<checkbox',styled_xml('内容摘要\n没有明确任务\n待确认事项\n谁负责\n转写原文\n[00:00:00] 片段 1\n正文'))
        client=Feishu();client.cli_mode=False;calls=[];client.call=lambda method,path,body:calls.append(body) or {}
        client.append('document','待办事项\n'+'长任务'*500+'\n责任人：待确认\n依据：[1]')
        todos=[b for call in calls for b in call['children'] if b['block_type']==17]
        self.assertEqual(len(todos),1);self.assertEqual(len(todos[0]['todo']['elements']),2)
