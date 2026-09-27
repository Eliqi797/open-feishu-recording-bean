"""Explicit synthetic long-document integration. Resume this same output dir after uncertainty."""
import json
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from bean.core import Store, atomic_write
from bean.providers import load_env
from bean.feishu import publish
load_env(Path('.env'))
root=Path('private/probes/feishu-long');root.mkdir(parents=True,exist_ok=True)
store=Store(root/'data',reserve_bytes=0)
record=store.initiate({'device_id':'synthetic-test','source_id':'long-document-v1','title':'录音豆长文拆分联调（合成文字）','size':1,'sha256':'0'*64})
rid=record['recording_id']
segments=[{'id':i,'text':f'第{i:03d}段。这里只验证长文拆分、链接与回读，不是真实会议，不来自 ASR。'+('测试内容保持完整。'*15)} for i in range(90)]
store.save_result(rid,'asr',{'source':'manual-reference-not-asr','segments':segments})
store.save_result(rid,'summary',{'summary':'合成长文测试，不用于语音识别验收。','decisions':[],'actions':[],'uncertainties':['全部内容都是合成测试数据。']})
result=publish(store,rid)
again=publish(store,rid)
report={'synthetic_text':True,'source_chars':sum(len(s['text']) for s in segments),'document_ids':[p['document_id'] for p in result['documents']],'api_readback_verified':result['api_readback_verified'],'repeat_same_ids':[p['document_id'] for p in result['documents']]==[p['document_id'] for p in again['documents']]}
atomic_write(root/'report.json',json.dumps(report,ensure_ascii=False,indent=2).encode());print(json.dumps(report,ensure_ascii=False))
