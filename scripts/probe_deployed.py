"""Bounded live deployment probe; credentials are read from a private file, never logged."""
import argparse
import hashlib
import http.client
import json
import socket
import ssl
from pathlib import Path
from urllib.parse import urlsplit


def main():
    p=argparse.ArgumentParser();p.add_argument('--origin',required=True);p.add_argument('--token-file',type=Path,required=True);p.add_argument('--resolve-ip');p.add_argument('--audio',type=Path,required=True);p.add_argument('--report',type=Path,required=True);args=p.parse_args()
    origin=urlsplit(args.origin)
    assert origin.scheme=='https' and origin.hostname and not origin.path and not origin.query
    token=args.token_file.read_text().strip();payload=args.audio.read_bytes();sha=hashlib.sha256(payload).hexdigest()
    class Connection(http.client.HTTPSConnection):
        def connect(self):
            self.sock=socket.create_connection((args.resolve_ip or self.host,self.port),timeout=self.timeout)
            self.sock=ssl.create_default_context().wrap_socket(self.sock,server_hostname=self.host)
    def request(method,path,data=None,headers=None,auth=True):
        h={'Authorization':'Bearer '+token} if auth else {};h.update(headers or {})
        if isinstance(data,dict):data=json.dumps(data).encode();h['Content-Type']='application/json'
        c=Connection(origin.hostname,origin.port or 443,timeout=60);c.request(method,path,data,h);r=c.getresponse();result=(r.status,r.read());c.close();return result
    def api(method,path,data=None,headers=None):
        code,raw=request(method,path,data,headers);assert code==200,(path,code);return json.loads(raw)
    assert request('GET','/api/recordings',auth=False)[0]==401
    assert request('GET','/api/recordings',headers={'Authorization':'Bearer invalid'})[0]==401
    assert request('POST','/api/uploads',{},headers={'Origin':'https://untrusted.example'})[0]==403
    metadata={'device_id':'deployment-probe','source_id':'gcp-synthetic-30s-v1','title':'上线验收：30秒合成测试语音（非真实会议）','size':len(payload),'sha256':sha,'mime':'audio/wav'}
    session=api('POST','/api/uploads',metadata)
    for i,at in enumerate(range(0,len(payload),session['chunk_size'])):
        block=payload[at:at+session['chunk_size']];api('PUT',f"/api/uploads/{session['upload_id']}/chunks/{i}",block,{'X-Chunk-SHA256':hashlib.sha256(block).hexdigest()})
    assert api('POST','/api/uploads',metadata)['upload_id']==session['upload_id']
    receipt=api('POST',f"/api/uploads/{session['upload_id']}/complete",{})
    assert receipt['verified'] and receipt['sha256']==sha
    path=f"/api/recordings/{receipt['recording_id']}/audio"
    assert request('GET',path,auth=False)[0]==401
    assert request('GET',path)[1]==payload
    assert request('GET',path,headers={'Range':'bytes=0-99'})==(206,payload[:100])
    assert api('POST','/api/uploads',metadata)['recording_id']==receipt['recording_id']
    api('POST',f"/api/recordings/{receipt['recording_id']}/pipeline",{})
    report={'origin':args.origin,'resolve_ip':args.resolve_ip,'recording_id':receipt['recording_id'],'tls_certificate_verified':True,'checks':['unauthorized 401','wrong token 401','cross-origin write 403','resumable upload','full audio SHA256 readback','protected playback','Range 206','duplicate idempotency'],'source':'synthetic 30 second bilingual WAV','pipeline':'started, not yet verified'}
    args.report.parent.mkdir(exist_ok=True,parents=True);args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False))


if __name__=='__main__':main()
