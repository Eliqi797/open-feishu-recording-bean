"""Local debug-only HDC file relay; no listener, public URL or device token needed.

The phone's debug build writes bounded requests in its own sandbox. Only this
project's live/upload routes are forwarded to loopback with the local access token.
Production networking continues to require HTTPS and the atomic-service allowlist.
"""
import argparse
import base64
import json
import re
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--device', required=True)
    p.add_argument('--bundle', required=True)
    p.add_argument('--hdc', default='/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc')
    args = p.parse_args()
    prefix = [args.hdc, '-t', args.device]
    remote = 'data/storage/el2/base/haps/entry/files/cloud-bridge/'
    local = Path('private/usb-relay')
    local.mkdir(mode=0o700, exist_ok=True)
    token = Path('data/access-token').read_text().strip()
    seen = set()
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    opener = urllib.request.build_opener(NoRedirect())
    def hdc(*parts):
        return subprocess.run(prefix + list(parts), capture_output=True, timeout=10)
    while True:
        result = hdc('shell', '-b', args.bundle, 'ls', remote)
        for name in result.stdout.decode(errors='replace').split():
            if not re.fullmatch(r'r[0-9]+-[0-9]+\.req\.json', name) or name in seen:
                continue
            reqfile = local / name
            if hdc('file', 'recv', '-b', args.bundle, remote + name, str(reqfile)).returncode or not reqfile.exists():
                continue
            try:
                if reqfile.stat().st_size > 6 * 1024 * 1024:
                    raise ValueError('large request')
                data = json.loads(reqfile.read_text())
                path, method = data['path'], data['method']
                route = re.fullmatch(r'/api/(?:live(?:/[a-f0-9]{32}(?:/(?:segments/[0-9]+|finish))?)?|uploads(?:/[a-f0-9]{32}/(?:chunks/[0-9]+|complete))?)', path)
                if not route or method not in ('GET', 'POST', 'PUT'):
                    raise ValueError('route not allowed')
                body = base64.b64decode(data['body'], validate=True) if data['binary'] else data['body'].encode()
                headers = {'Authorization': 'Bearer ' + token, 'Content-Type': 'application/octet-stream' if data['binary'] else 'application/json',
                           'X-Chunk-SHA256': data['sha256'], 'X-Audio-Duration-Ms': str(data['duration'])}
                request = urllib.request.Request('http://127.0.0.1:8765' + path, data=None if method == 'GET' else body, method=method, headers=headers)
                try:
                    with opener.open(request, timeout=30) as response:
                        answer = {'status': response.status, 'body': response.read().decode()}
                except urllib.error.HTTPError as e:
                    answer = {'status': e.code, 'body': e.read().decode()}
            except Exception:
                answer = {'status': 502, 'body': '{"error":"DEBUG_USB_RELAY_FAILED"}'}
            outname = name.replace('.req.', '.res.')
            outfile = local / outname
            outfile.write_text(json.dumps(answer, ensure_ascii=False))
            outfile.chmod(0o600)
            # Publish a ready marker only after the complete response file is transferred.
            pushed = hdc('file', 'send', '-b', args.bundle, str(outfile), remote + outname)
            if b'FileTransfer finish' in pushed.stdout:
                ready = local / 'ready';ready.write_text('ok')
                marked = hdc('file', 'send', '-b', args.bundle, str(ready), remote + name.replace('.req.json', '.ready'))
                if b'FileTransfer finish' in marked.stdout:
                    seen.add(name)
            reqfile.unlink(missing_ok=True)
            outfile.unlink(missing_ok=True)
        time.sleep(0.4)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
