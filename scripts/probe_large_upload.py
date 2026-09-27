"""Generate three hours of digital silence and exercise the real local HTTP upload.
This verifies capacity/integrity only; it must never be labeled ASR or device acceptance.
"""
import hashlib,json,time,urllib.request,wave
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=root/'private/samples/synthetic-silence-3h.wav'
with wave.open(str(p),'wb') as w:
 w.setparams((1,2,16000,0,'NONE',''))
 block=bytes(32000*30)
 for _ in range(360):w.writeframesraw(block)
with p.open('rb') as f:checksum=hashlib.file_digest(f,'sha256').hexdigest()
token=(root/'data/access-token').read_text().strip()
def request(method,path,body=None,headers=None):
 h={'Authorization':'Bearer '+token};h.update(headers or {})
 if isinstance(body,dict):body=json.dumps(body).encode();h['Content-Type']='application/json'
 req=urllib.request.Request('http://127.0.0.1:8765'+path,method=method,data=body,headers=h)
 return urllib.request.urlopen(req,timeout=90)
def api(method,path,body=None,headers=None):
 with request(method,path,body,headers) as r:return json.load(r)
start=time.monotonic()
metadata={'device_id':'manual-capacity-test','source_id':'synthetic-silence-3h-v1','title':'3小时静音容量测试（不测 ASR）','size':p.stat().st_size,'sha256':checksum,'mime':'audio/wav'}
session=api('POST','/api/uploads',metadata)
with p.open('rb') as f:
 index=0
 while block:=f.read(session['chunk_size']):
  api('PUT',f"/api/uploads/{session['upload_id']}/chunks/{index}",block,{'X-Chunk-SHA256':hashlib.sha256(block).hexdigest()})
  index+=1
  if index==1:
   resume=api('POST','/api/uploads',metadata)
   assert resume['upload_id']==session['upload_id'] and len(resume['chunks'])==1
receipt=api('POST',f"/api/uploads/{session['upload_id']}/complete",{})
assert receipt['verified'] and receipt['sha256']==checksum
out=hashlib.sha256();size=0
with request('GET',f"/api/recordings/{session['recording_id']}/audio") as r:
 while b:=r.read(1024*1024):out.update(b);size+=len(b)
assert size==metadata['size'] and out.hexdigest()==checksum
again=api('POST','/api/uploads',metadata);assert again['recording_id']==session['recording_id']
report={'audio_hours':3,'bytes':size,'chunks':index,'elapsed_seconds':round(time.monotonic()-start,2),'source':'digital silence generated locally','checks':['resume first chunk','full hash readback','duplicate same recording'],'asr_verified':False,'recording_id':session['recording_id']}
(root/'private/probes/large-upload.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False))
