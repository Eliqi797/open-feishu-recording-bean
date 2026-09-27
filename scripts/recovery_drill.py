"""Restore to a new isolated local directory, verify every file, then test protected playback.
Never runs a processing worker, calls a provider, or changes the source backup.
"""
import argparse
import hashlib
import http.client
import json
import sys
import threading
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from scripts.backup import restore
from bean.core import Store, atomic_write
from bean.server import App

def drill(snapshot, destination):
    restore(snapshot,destination)
    store=Store(destination,reserve_bytes=0)
    app=App(('127.0.0.1',0),store)
    thread=threading.Thread(target=app.serve_forever,daemon=True);thread.start()
    with store.db() as db: ids=[r[0] for r in db.execute('SELECT id FROM recordings')]
    records=[store.recording(rid) for rid in ids];verified=0
    try:
        for r in records:
            if not r['stored']:continue
            path='/api/recordings/'+r['id']+'/audio'
            c=http.client.HTTPConnection('127.0.0.1',app.server_port)
            c.request('GET',path);response=c.getresponse();response.read()
            if response.status!=401:raise RuntimeError('RESTORE_AUTH_FAILED')
            c.close();c=http.client.HTTPConnection('127.0.0.1',app.server_port)
            c.request('GET',path,headers={'Authorization':'Bearer '+app.token})
            response=c.getresponse();checksum=hashlib.sha256();count=0
            if response.status!=200:raise RuntimeError('RESTORE_PLAYBACK_FAILED')
            while block:=response.read(1024*1024):checksum.update(block);count+=len(block)
            c.close()
            if checksum.hexdigest()!=r['sha256'] or count!=r['size']:raise RuntimeError('RESTORE_CONTENT_MISMATCH')
            verified+=1
        return {'restored_recordings':len(records),'protected_audio_verified':verified,
                'checks':['manifest hashes','sqlite integrity','unauthorized 401','authenticated audio exact SHA256'],
                'independent_storage_verified':False,'providers_called':False}
    finally:app.shutdown();app.server_close();thread.join()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('snapshot',type=Path);p.add_argument('destination',type=Path);p.add_argument('--report',type=Path,required=True);args=p.parse_args()
    value=drill(args.snapshot,args.destination);atomic_write(args.report,json.dumps(value,ensure_ascii=False,indent=2).encode());print(json.dumps(value,ensure_ascii=False))
