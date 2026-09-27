"""Durable, provisional live captions. Final publications use the verified full audio.

Each bounded audio window is independent: speaker IDs never merge across windows.
An interrupted stream is not a complete recording and cannot trigger publication.
"""
import hashlib
import json
import shutil
import time
import uuid

from .settings import Settings, scope

from .core import Problem, atomic_write, digest, integer, sha_field, text_field
from .providers import transcribe


class LiveStore:
    max_segment_bytes = 1024 * 1024

    def __init__(self, store):
        self.store = store
        self.root = store.root / 'results' / 'live'
        self.root.mkdir(exist_ok=True, mode=0o700)
        with store.db() as db:
            db.executescript('''
            CREATE TABLE IF NOT EXISTS live_sessions (
              id TEXT PRIMARY KEY, device_id TEXT NOT NULL, source_id TEXT NOT NULL,
              title TEXT NOT NULL, status TEXT NOT NULL, created REAL NOT NULL,
              recording_id TEXT, UNIQUE(device_id,source_id));
            CREATE TABLE IF NOT EXISTS live_segments (
              session_id TEXT NOT NULL, idx INTEGER NOT NULL, duration_ms INTEGER NOT NULL,
              sha256 TEXT NOT NULL, size INTEGER NOT NULL, status TEXT NOT NULL,
              error TEXT, PRIMARY KEY(session_id,idx),
              FOREIGN KEY(session_id) REFERENCES live_sessions(id));
            ''')
            columns={r[1] for r in db.execute('PRAGMA table_info(live_sessions)')}
            if 'original_source_id' not in columns:
                db.execute("ALTER TABLE live_sessions ADD COLUMN original_source_id TEXT NOT NULL DEFAULT ''")
                db.execute("UPDATE live_sessions SET original_source_id=source_id")
            if 'start_ms' not in columns:
                db.execute("ALTER TABLE live_sessions ADD COLUMN start_ms INTEGER NOT NULL DEFAULT 0")
            if 'window_ms' not in columns:
                db.execute("ALTER TABLE live_sessions ADD COLUMN window_ms INTEGER NOT NULL DEFAULT 20000")
            db.execute("UPDATE live_segments SET status='queued',error='PROCESS_INTERRUPTED' WHERE status='running'")

    def begin(self, data):
        device, source, title = (text_field(data.get(k)) for k in ('device_id', 'source_id', 'title'))
        original=text_field(data.get('original_source_id',source))
        start=integer(data.get('start_ms',0),0,2**53-1)
        window=integer(data.get('window_ms',20000),2000,20000)
        if window not in (2000,5000,10000,20000):raise Problem('LIVE_WINDOW_INVALID',422)
        with self.store.lock, self.store.db() as db:
            row = db.execute('SELECT * FROM live_sessions WHERE device_id=? AND source_id=?', (device, source)).fetchone()
            if row:
                if row['original_source_id']!=original or row['start_ms']!=start or row['window_ms']!=window:
                    raise Problem('LIVE_SESSION_METADATA_CONFLICT',409)
                sid = row['id']
            else:
                sid = uuid.uuid4().hex
                (self.root / sid).mkdir(mode=0o700)
                db.execute('INSERT INTO live_sessions(id,device_id,source_id,title,status,created,original_source_id,start_ms,window_ms) VALUES(?,?,?,?,?,?,?,?,?)', (sid, device, source, title, 'capturing', time.time(),original,start,window))
        return self.status(sid)

    def session(self, sid):
        with self.store.db() as db:
            row = db.execute('SELECT * FROM live_sessions WHERE id=?', (sid,)).fetchone()
        if not row:
            raise Problem('LIVE_SESSION_NOT_FOUND', 404)
        return dict(row)

    def status(self, sid):
        session = self.session(sid)
        with self.store.db() as db:
            rows = [dict(r) for r in db.execute('SELECT * FROM live_segments WHERE session_id=? ORDER BY idx', (sid,))]
        elapsed = 0
        for row in rows:
            row['start_ms'] = session['start_ms'] + elapsed
            elapsed += row['duration_ms']
            row['text'] = ''
            if row['status'] == 'completed':
                path = self.root / sid / f"{row['idx']}.json"
                if path.exists():
                    row['text'] = json.loads(path.read_text())['text']
                else:
                    row['status'], row['error'] = 'failed', 'LIVE_RESULT_MISSING'
        return {**session, 'session_id': sid, 'segments': rows, 'received_ms': elapsed,
                'provisional': True, 'text': '\n'.join(r['text'] for r in rows if r['text']),
                'note': '分段实时草稿，边界文字和说话人待核对；最终纪要依据完整音频另行处理。'}

    def put(self, sid, idx, payload, sha, duration):
        integer(idx, 0, 54000)  # bounded index, up to 300 hours of 20 s windows
        integer(duration, 20, 20000)
        sha_field(sha)
        if duration % 20 or not 1 <= len(payload) <= self.max_segment_bytes or not payload.startswith(b'OggS'):
            raise Problem('LIVE_SEGMENT_INVALID', 422)
        if hashlib.sha256(payload).hexdigest() != sha:
            raise Problem('CHUNK_CHECKSUM_MISMATCH', 422)
        with self.store.lock, self.store.db() as db:
            session = self.session(sid)
            if duration > session['window_ms']:raise Problem('LIVE_SEGMENT_TOO_LONG',422)
            old = db.execute('SELECT * FROM live_segments WHERE session_id=? AND idx=?', (sid, idx)).fetchone()
            if old:
                if (old['sha256'], old['size'], old['duration_ms']) != (sha, len(payload), duration):
                    raise Problem('LIVE_SEGMENT_CONFLICT', 409)
                path = self.root / sid / f'{idx}.ogg'
                if not path.exists() or digest(path) != sha:
                    raise Problem('LIVE_STORED_SEGMENT_CORRUPT', 409)
                return {'verified': True, 'sha256': sha, 'idx': idx, 'size': len(payload)}
            if session['status'] != 'capturing':
                raise Problem('LIVE_SESSION_CLOSED', 409)
            count = db.execute('SELECT COUNT(*) FROM live_segments WHERE session_id=?', (sid,)).fetchone()[0]
            if idx != count:
                raise Problem('LIVE_SEGMENT_GAP', 409)
            if idx and db.execute('SELECT duration_ms FROM live_segments WHERE session_id=? AND idx=?', (sid, idx - 1)).fetchone()[0] != session['window_ms']:
                raise Problem('LIVE_SHORT_SEGMENT_MUST_BE_LAST', 409)
            if shutil.disk_usage(self.root).free < self.store.reserve_bytes + len(payload):
                raise Problem('INSUFFICIENT_STORAGE', 507)
            atomic_write(self.root / sid / f'{idx}.ogg', payload)
            db.execute('INSERT INTO live_segments VALUES(?,?,?,?,?,?,NULL)', (sid, idx, duration, sha, len(payload), 'queued'))
        return {'verified': True, 'sha256': sha, 'idx': idx, 'size': len(payload)}

    def finish(self, sid, data):
        # Ending reception is NOT equivalent to ending the device recording.
        if data.get('device_end_observed') is not True:
            raise Problem('LIVE_DEVICE_END_REQUIRED', 409)
        rid = text_field(data.get('recording_id'), 32)
        count = integer(data.get('segment_count'), 1, 54001)
        with self.store.lock:
            session = self.session(sid)
            recording = self.store.recording(rid)
            if not recording['stored'] or recording['source_id']!=session['original_source_id'] or (recording['device_id']!=session['device_id'] and session['device_id'] not in recording.get('source_devices',[])):
                raise Problem('LIVE_FINAL_RECORDING_MISMATCH', 409)
            if digest(self.store.root / 'audio' / rid) != recording['sha256']:
                raise Problem('STORED_AUDIO_CORRUPT', 409)
            with self.store.db() as db:
                actual = db.execute('SELECT COUNT(*) FROM live_segments WHERE session_id=?', (sid,)).fetchone()[0]
                if actual != count:
                    raise Problem('LIVE_FINAL_SEGMENT_COUNT_MISMATCH', 409)
                if session['recording_id'] and session['recording_id'] != rid:
                    raise Problem('LIVE_FINAL_RECORDING_CONFLICT', 409)
                db.execute("UPDATE live_sessions SET status='completed',recording_id=? WHERE id=?", (rid, sid))
            self.store.start_pipeline(rid)
        return self.status(sid)

    def retry(self, sid, idx):
        self.session(sid)
        with self.store.lock, self.store.db() as db:
            db.execute("UPDATE live_segments SET status='queued',error=NULL WHERE session_id=? AND idx=? AND status='failed'", (sid, idx))
        return self.status(sid)

    def once(self):
        with scope(Settings(self.store.root).snapshot()):
            return self._once()

    def _once(self):
        with self.store.lock, self.store.db() as db:
            row = db.execute("SELECT * FROM live_segments WHERE status='queued' ORDER BY rowid LIMIT 1").fetchone()
            if not row:
                return False
            sid, idx = row['session_id'], row['idx']
            db.execute("UPDATE live_segments SET status='running',error=NULL WHERE session_id=? AND idx=?", (sid, idx))
        base = self.root / sid
        try:
            if digest(base / f'{idx}.ogg') != row['sha256']:
                raise Problem('LIVE_STORED_SEGMENT_CORRUPT', 409)
            result = transcribe(base / f'{idx}.ogg', base / f'{idx}.raw.json')
            if abs(result['metrics']['audio_seconds'] * 1000 - row['duration_ms']) > 100:
                raise Problem('LIVE_SEGMENT_DURATION_MISMATCH', 422)
            for segment in result['segments']:
                for word in segment['words']:
                    if word['speaker_id'] is not None:
                        word['speaker_id'] = f"window_{idx}:{word['speaker_id']}"
            result['provisional'] = True
            atomic_write(base / f'{idx}.json', json.dumps(result, ensure_ascii=False).encode())
            status, error = 'completed', None
        except Problem as e:
            # Silence/no recognized speech is visible, never invented as a transcript.
            status, error = ('no_speech', e.code) if e.code == 'ASR_NO_FINAL_TRANSCRIPT' else ('failed', e.code)
        except Exception:
            status, error = 'failed', 'LIVE_PROCESSING_ERROR'
        with self.store.lock, self.store.db() as db:
            db.execute('UPDATE live_segments SET status=?,error=? WHERE session_id=? AND idx=?', (status, error, sid, idx))
        return True
