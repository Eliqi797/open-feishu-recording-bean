from __future__ import annotations

import argparse
import fcntl
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from .core import Problem, Store, atomic_write
from .providers import capabilities, load_env
from .worker import Worker
from .settings import Settings, scope
from .feishu import reconcile_document
from .playback import compatible_audio

WEB = Path(__file__).resolve().parent.parent / "web"


class App(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, store):
        self.store = store
        token_path = store.root / "access-token"
        if not token_path.exists():
            atomic_write(token_path, secrets.token_urlsafe(32).encode())
        self.token = token_path.read_text().strip()
        self.sessions = {}
        self.login_failures = {}
        self.auth_lock = threading.Lock()
        self.playback_lock = threading.Lock()
        self.settings = Settings(store.root)
        self.worker = Worker(store)
        super().__init__(address, Handler)


class Handler(BaseHTTPRequestHandler):
    server_version = "RecordingBean/0.1"

    def setup(self):
        super().setup()
        self.connection.settimeout(30)

    def log_message(self, *args):
        pass  # Paths may include private recording IDs. No access-log secrets.

    def headers_out(self, status, content_type, size, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; media-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()

    def json(self, data, status=200, extra=None):
        raw = json.dumps(data, ensure_ascii=False, allow_nan=False).encode()
        self.headers_out(status, "application/json; charset=utf-8", len(raw), extra)
        self.wfile.write(raw)

    def body(self, maximum):
        try:
            size = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            raise Problem("INVALID_CONTENT_LENGTH", 400)
        if size < 0 or size > maximum or self.headers.get("Transfer-Encoding"):
            raise Problem("INVALID_BODY_SIZE", 413)
        payload = self.rfile.read(size)
        if len(payload) != size:
            raise Problem("INCOMPLETE_BODY")
        return payload

    def body_json(self):
        try:
            data = json.loads(self.body(1024 * 1024))
            if not isinstance(data, dict):
                raise ValueError()
            return data
        except (ValueError, UnicodeError):
            raise Problem("INVALID_JSON") from None

    def check_origin(self):
        # A fixed loopback allowlist blocks DNS rebinding; do not trust arbitrary Host headers.
        port = self.server.server_port
        public = os.getenv("PUBLIC_ORIGIN", "").rstrip("/")
        allowed = {f"http://127.0.0.1:{port}", f"http://localhost:{port}"}
        if public:
            allowed.add(public)
        hosts = {urlsplit(v).netloc for v in allowed}
        if self.headers.get("Host") not in hosts:
            raise Problem("HOST_NOT_ALLOWED", 403)
        origin = self.headers.get("Origin")
        if origin and origin not in allowed:
            raise Problem("ORIGIN_NOT_ALLOWED", 403)
        if self.command in ("POST", "PUT") and self.headers.get("Cookie") and not origin and not self.headers.get("Authorization"):
            raise Problem("ORIGIN_REQUIRED", 403)

    def require_auth(self):
        bearer = self.headers.get("Authorization", "")
        if bearer.startswith("Bearer ") and hmac.compare_digest(bearer[7:], self.server.token):
            return
        cookies = SimpleCookie()
        try:
            cookies.load(self.headers.get("Cookie", ""))
        except Exception:
            raise Problem("AUTH_REQUIRED", 401)
        session = cookies.get("bean_session")
        if session:
            hashed = hashlib.sha256(session.value.encode()).hexdigest()
            with self.server.auth_lock:
                if self.server.sessions.get(hashed, 0) > time.time():
                    return
        raise Problem("AUTH_REQUIRED", 401)

    def login(self):
        peer = self.client_address[0]
        with self.server.auth_lock:
            count, until = self.server.login_failures.get(peer, (0, 0))
            if count >= 10 and until > time.time():
                raise Problem("LOGIN_RATE_LIMITED", 429)
        token = self.body_json().get("token", "")
        if not isinstance(token, str) or not hmac.compare_digest(token, self.server.token):
            with self.server.auth_lock:
                self.server.login_failures[peer] = (count + 1 if until > time.time() else 1, time.time() + 60)
            raise Problem("INVALID_ACCESS_TOKEN", 401)
        session = secrets.token_urlsafe(32)
        with self.server.auth_lock:
            self.server.sessions = {k: v for k, v in self.server.sessions.items() if v > time.time()}
            self.server.sessions[hashlib.sha256(session.encode()).hexdigest()] = time.time() + 12 * 3600
            self.server.login_failures.pop(peer, None)
        secure = "; Secure" if os.getenv("PUBLIC_ORIGIN", "").startswith("https://") else ""
        self.json({"authenticated": True}, extra={"Set-Cookie": f"bean_session={session}; HttpOnly; SameSite=Strict; Path=/; Max-Age=43200{secure}"})

    def dispatch(self):
        self.check_origin()
        path = urlsplit(self.path).path
        store = self.server.store
        if self.command == "GET" and path in ("/", "/app.js", "/style.css", "/sha256.js"):
            name = "index.html" if path == "/" else path[1:]
            payload = (WEB / name).read_bytes()
            mime = {"html": "text/html", "js": "text/javascript", "css": "text/css"}[name.split(".")[-1]]
            self.headers_out(200, mime + "; charset=utf-8", len(payload))
            self.wfile.write(payload)
            return
        if path == "/healthz" and self.command == "GET":
            return self.json({"status": "ok", "version": "0.1.0", "deployment": "https" if os.getenv("PUBLIC_ORIGIN", "").startswith("https://") else "local"})
        if path == "/api/login" and self.command == "POST":
            return self.login()
        self.require_auth()
        if path == "/api/logout" and self.command == "POST":
            cookies = SimpleCookie(self.headers.get("Cookie", ""))
            if cookies.get("bean_session"):
                with self.server.auth_lock:
                    self.server.sessions.pop(hashlib.sha256(cookies["bean_session"].value.encode()).hexdigest(), None)
            return self.json({"ok": True}, extra={"Set-Cookie": "bean_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"})
        if path == '/api/settings' and self.command == 'GET':
            return self.json(self.server.settings.public())
        if path == '/api/settings' and self.command == 'POST':
            return self.json(self.server.settings.update(self.body_json()))
        if path == "/api/capabilities" and self.command == "GET":
            with scope(self.server.settings.snapshot()):
                return self.json(capabilities())
        if path == "/api/recordings" and self.command == "GET":
            return self.json({"recordings": store.listing()})
        if path == '/api/diagnostics' and self.command == 'GET':
            import shutil
            with store.db() as db:
                counts = {r[0]: r[1] for r in db.execute('SELECT status,COUNT(*) FROM jobs GROUP BY status')}
            return self.json({'jobs': counts, 'free_bytes': shutil.disk_usage(store.root).free,
                              'worker_alive': bool(self.server.worker.thread and self.server.worker.thread.is_alive()),
                              'live_worker_alive': bool(self.server.worker.live_thread and self.server.worker.live_thread.is_alive()),
                              'backup_report': json.loads((store.root / 'last-backup.json').read_text()) if (store.root / 'last-backup.json').exists() else None})
        action_match = re.fullmatch(r'/api/recordings/([a-f0-9]{32})/(pipeline|pause|reference|reconcile)', path)
        if action_match and self.command == 'POST':
            rid, action = action_match.groups()
            body = self.body_json()
            if action == 'pipeline':
                return self.json(store.start_pipeline(rid))
            if action == 'pause':
                return self.json(store.pause_pipeline(rid))
            if action == 'reference':
                if body.get('source') != 'manual-reference-not-asr':
                    raise Problem('REFERENCE_SOURCE_MUST_BE_EXPLICIT')
                return self.json(store.import_reference(rid, body.get('text')))
            part = body.get('part')
            if type(part) is not int or part < 0:
                raise Problem('INVALID_DOCUMENT_PART')
            with scope(self.server.settings.snapshot()):
                return self.json(reconcile_document(store, rid, part, body.get('document_id')))
        if path == '/api/live' and self.command == 'POST':
            return self.json(self.server.worker.live.begin(self.body_json()))
        live_match = re.fullmatch(r'/api/live/([a-f0-9]{32})(?:/(finish|segments/([0-9]+)(/retry)?))?', path)
        if live_match:
            sid, action, index, retry = live_match.groups()
            live = self.server.worker.live
            if self.command == 'GET' and action is None:
                return self.json(live.status(sid))
            if self.command == 'POST' and action == 'finish':
                return self.json(live.finish(sid, self.body_json()))
            if self.command == 'POST' and retry:
                self.body_json()
                return self.json(live.retry(sid, int(index)))
            if self.command == 'PUT' and index is not None and not retry:
                try:
                    duration = int(self.headers.get('X-Audio-Duration-Ms', ''))
                except ValueError:
                    raise Problem('LIVE_DURATION_REQUIRED') from None
                return self.json(live.put(sid, int(index), self.body(live.max_segment_bytes),
                                         self.headers.get('X-Chunk-SHA256'), duration))
        if path == "/api/uploads" and self.command == "POST":
            return self.json(store.initiate(self.body_json()))
        match = re.fullmatch(r"/api/uploads/([a-f0-9]{32})(?:/(complete|chunks/([0-9]+)))?", path)
        if match:
            uid, action, idx = match.groups()
            if self.command == "GET" and action is None:
                return self.json(store.upload_status(uid))
            if self.command == "PUT" and idx is not None:
                payload = self.body(store.chunk_size)
                return self.json(store.put_chunk(uid, int(idx), payload, self.headers.get("X-Chunk-SHA256")))
            if self.command == "POST" and action == "complete":
                value = store.complete(uid)
                if self.server.settings.snapshot()["AUTO_PIPELINE"] == "1":
                    store.start_pipeline(value["recording_id"])
                return self.json(value)
        match = re.fullmatch(r"/api/recordings/([a-f0-9]{32})(?:/(audio|result/(asr|diarization|summary|feishu)|jobs/(asr|diarization|summary|feishu)))?", path)
        if match:
            rid, action, result_stage, job_stage = match.groups()
            r = store.recording(rid)
            if self.command == "GET" and action is None:
                return self.json(r)
            if self.command == "GET" and result_stage:
                return self.json(store.result(rid, result_stage))
            if self.command == "POST" and job_stage:
                return self.json(store.enqueue(rid, job_stage))
            if self.command == "GET" and action == "audio":
                return self.audio(r)
        raise Problem("NOT_FOUND", 404)

    def audio(self, recording):
        if not recording["stored"]:
            raise Problem("AUDIO_NOT_STORED", 409)
        path = self.server.store.root / "audio" / recording["id"]
        if not path.exists() or path.stat().st_size != recording["size"]:
            raise Problem("STORED_AUDIO_CORRUPT", 409)
        variant = urlsplit(self.path).query
        if variant == "format=mp3":
            with self.server.playback_lock:
                path = compatible_audio(self.server.store, recording)
                source = path.open("rb")
            mime = "audio/mpeg"
        elif not variant:
            source = path.open("rb")
            mime = recording["mime"]
        else:
            raise Problem("INVALID_AUDIO_FORMAT", 400)
        try:
            return self._send_audio(source, mime)
        finally:
            source.close()

    def _send_audio(self, source, mime):
        size = os.fstat(source.fileno()).st_size
        start, end, status, extra = 0, size - 1, 200, {"Accept-Ranges": "bytes"}
        value = self.headers.get("Range")
        if value:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
            if not match or not any(match.groups()):
                raise Problem("INVALID_RANGE", 416)
            left, right = match.groups()
            if not left:
                start = max(0, size - int(right))
            else:
                start, end = int(left), min(size - 1, int(right)) if right else size - 1
            if not 0 <= start <= end < size:
                self.headers_out(416, "application/octet-stream", 0, {"Content-Range": f"bytes */{size}"})
                return
            status = 206
            extra["Content-Range"] = f"bytes {start}-{end}/{size}"
        self.headers_out(status, mime, end - start + 1, extra)
        source.seek(start)
        remaining = end - start + 1
        while remaining:
            part = source.read(min(65536, remaining))
            if not part:
                break
            self.wfile.write(part)
            remaining -= len(part)

    def handle_request(self):
        try:
            self.dispatch()
        except Problem as e:
            self.json({"error": e.code}, e.status)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except OSError:
            self.json({"error": "STORAGE_OR_IO_ERROR"}, 503)
        except Exception:
            self.json({"error": "INTERNAL_ERROR"}, 500)

    do_GET = do_POST = do_PUT = handle_request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--data", type=Path, default=Path("data"))
    args = parser.parse_args()
    load_env(Path(".env"))
    os.umask(0o077)
    args.data.mkdir(exist_ok=True, parents=True)
    lock = (args.data / "server.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.exit(1, "已有进程正在使用这个数据目录。\n")
    store = Store(args.data)
    server = App(("127.0.0.1", args.port), store)
    server.worker.start()
    print(f"本地工作台：http://127.0.0.1:{server.server_port}", flush=True)
    print(f"访问口令保存在：{store.root / 'access-token'}（不要上传到 Git）", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.worker.stop.set()
        server.server_close()
        lock.close()


if __name__ == "__main__":
    main()
