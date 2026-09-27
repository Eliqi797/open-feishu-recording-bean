"""Read-only local health check. No message sending and no credential output."""
import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


def check(origin, token_path, reserve=512*1024**2):
    if origin not in ('http://127.0.0.1:8765', 'http://localhost:8765'):
        raise ValueError('Only the local backend health endpoint is supported')
    token = token_path.read_text().strip()
    request = urllib.request.Request(origin+'/api/diagnostics', headers={'Authorization':'Bearer '+token})
    with urllib.request.urlopen(request, timeout=10) as res:
        state = json.load(res)
    problems = []
    if not state['worker_alive']: problems.append('WORKER_NOT_RUNNING')
    if state['free_bytes'] < reserve: problems.append('LOW_DISK_SPACE')
    if state['jobs'].get('failed',0) or state['jobs'].get('blocked',0): problems.append('JOBS_REQUIRE_ATTENTION')
    if not state.get('backup_report') or time.time()-state['backup_report']['created']>48*3600: problems.append('BACKUP_MISSING_OR_STALE')
    return {'healthy': not problems, 'problems': problems, **state}

if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('--token-file', type=Path, default=Path('data/access-token'))
    p.add_argument('--origin', default='http://127.0.0.1:8765');args=p.parse_args()
    try:
        result=check(args.origin,args.token_file);print(json.dumps(result,ensure_ascii=False));sys.exit(0 if result['healthy'] else 1)
    except Exception:
        print('{"healthy":false,"problems":["HEALTH_CHECK_UNAVAILABLE"]}');sys.exit(2)
