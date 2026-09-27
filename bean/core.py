from __future__ import annotations

import contextlib
import hashlib
import json
import math
import os
import re
import shutil
import sqlite3
import threading
import time
import uuid
from pathlib import Path


class Problem(Exception):
    def __init__(self, code: str, status: int = 400):
        super().__init__(code)
        self.code, self.status = code, status


def digest(path: Path) -> str:
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def atomic_write(path: Path, data: bytes):
    tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with tmp.open("xb") as f:
            os.chmod(tmp, 0o600)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        tmp.unlink(missing_ok=True)


def text_field(value, maximum=200):
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise Problem("INVALID_TEXT")
    return value.strip()


def sha_field(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{64}", value):
        raise Problem("INVALID_SHA256")
    return value


def integer(value, low, high):
    if type(value) is not int or not low <= value <= high:
        raise Problem("INVALID_INTEGER")
    return value


STAGES = ("asr", "diarization", "summary", "feishu")


class Store:
    chunk_size = 4 * 1024 * 1024
    max_size = 4 * 1024**3

    def __init__(self, root: Path, reserve_bytes=512 * 1024**2):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        for name in ("audio", "uploads", "results"):
            (self.root / name).mkdir(exist_ok=True, mode=0o700)
        self.lock = threading.RLock()
        self.reserve_bytes = reserve_bytes
        with self.db() as db:
            db.executescript("""
            CREATE TABLE IF NOT EXISTS recordings (
              id TEXT PRIMARY KEY, device_id TEXT NOT NULL, source_id TEXT NOT NULL,
              title TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL,
              sha256 TEXT NOT NULL, created REAL NOT NULL, stored INTEGER DEFAULT 0,
              UNIQUE(device_id, source_id, sha256)
            );
            CREATE TABLE IF NOT EXISTS recording_sources (
              device_id TEXT NOT NULL, source_id TEXT NOT NULL, sha256 TEXT NOT NULL,
              recording_id TEXT NOT NULL REFERENCES recordings(id),
              PRIMARY KEY(device_id,source_id,sha256)
            );
            CREATE TABLE IF NOT EXISTS uploads (
              id TEXT PRIMARY KEY, recording_id TEXT NOT NULL UNIQUE,
              FOREIGN KEY(recording_id) REFERENCES recordings(id)
            );
            CREATE TABLE IF NOT EXISTS chunks (
              upload_id TEXT NOT NULL, idx INTEGER NOT NULL, sha256 TEXT NOT NULL,
              size INTEGER NOT NULL, PRIMARY KEY(upload_id, idx)
            );
            CREATE TABLE IF NOT EXISTS jobs (
              recording_id TEXT NOT NULL, stage TEXT NOT NULL, status TEXT NOT NULL,
              attempts INTEGER DEFAULT 0, error TEXT, updated REAL NOT NULL,
              PRIMARY KEY(recording_id, stage)
            );
            CREATE TABLE IF NOT EXISTS publications (
              recording_id TEXT NOT NULL, part INTEGER NOT NULL,
              status TEXT NOT NULL, document_id TEXT, content_hash TEXT NOT NULL,
              title TEXT NOT NULL, error TEXT,
              PRIMARY KEY(recording_id, part)
            );
            """)
            columns = {row[1] for row in db.execute("PRAGMA table_info(jobs)")}
            if "retry_at" not in columns:
                db.execute("ALTER TABLE jobs ADD COLUMN retry_at REAL NOT NULL DEFAULT 0")
            if "autoprocess" not in {row[1] for row in db.execute("PRAGMA table_info(recordings)")}:
                db.execute("ALTER TABLE recordings ADD COLUMN autoprocess INTEGER NOT NULL DEFAULT 0")
            if "recorded_at" not in {row[1] for row in db.execute("PRAGMA table_info(recordings)")}:
                db.execute("ALTER TABLE recordings ADD COLUMN recorded_at INTEGER")
                # Legacy D3200 BLE imports: file IDs encode device UTC start time.
                for row in db.execute("SELECT id,device_id,source_id FROM recordings").fetchall():
                    if re.fullmatch(r'(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}',row['device_id']) and row['source_id'].isdigit() and 946684800<=int(row['source_id'])<=4102444800:
                        db.execute('UPDATE recordings SET recorded_at=? WHERE id=?',(int(row['source_id']),row['id']))
            # A killed process must never report an in-flight stage as completed.
            db.execute("UPDATE jobs SET status='interrupted', error='PROCESS_INTERRUPTED' WHERE status='running'")
            db.execute("UPDATE jobs SET status='queued', retry_at=0 WHERE status='interrupted' AND recording_id IN (SELECT id FROM recordings WHERE autoprocess=1)")
            # Recover the crash window between marking a stage complete and enqueueing the next.
            for row in db.execute('SELECT id FROM recordings WHERE autoprocess=1').fetchall():
                jobs = {j['stage']: j['status'] for j in db.execute('SELECT * FROM jobs WHERE recording_id=?', (row['id'],))}
                for stage in STAGES:
                    if jobs.get(stage) != 'completed':
                        if jobs.get(stage) == 'pending':
                            db.execute("UPDATE jobs SET status='queued',retry_at=0 WHERE recording_id=? AND stage=?", (row['id'], stage))
                        break
                else:
                    db.execute('UPDATE recordings SET autoprocess=0 WHERE id=?', (row['id'],))

    @contextlib.contextmanager
    def db(self):
        conn = sqlite3.connect(self.root / "state.sqlite3", timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
        conn.execute("PRAGMA synchronous=FULL")
        try:
            with conn:
                yield conn
        finally:
            conn.close()

    def recording(self, rid):
        with self.db() as db:
            row = db.execute("SELECT * FROM recordings WHERE id=?", (rid,)).fetchone()
            if not row:
                raise Problem("RECORDING_NOT_FOUND", 404)
            result = dict(row)
            result['source_devices'] = [r[0] for r in db.execute('SELECT device_id FROM recording_sources WHERE recording_id=?',(rid,))]
            result["jobs"] = sorted([dict(j) for j in db.execute("SELECT * FROM jobs WHERE recording_id=?", (rid,))], key=lambda j: STAGES.index(j["stage"]))
            result["publications"] = [dict(p) for p in db.execute("SELECT * FROM publications WHERE recording_id=? ORDER BY part", (rid,))]
            return result

    def listing(self):
        with self.db() as db:
            ids = [r[0] for r in db.execute("SELECT id FROM recordings ORDER BY created DESC LIMIT 500")]
        return [self.recording(rid) for rid in ids]

    def initiate(self, data):
        device = text_field(data.get("device_id"))
        source = text_field(data.get("source_id"))
        title = text_field(data.get("title"))
        size = integer(data.get("size"), 1, self.max_size)
        sha = sha_field(data.get("sha256"))
        recorded_at=data.get("recorded_at")
        if recorded_at is not None:recorded_at=integer(recorded_at,946684800,4102444800)
        mime = data.get("mime", "audio/wav")
        if mime not in ("audio/wav", "audio/ogg", "audio/mpeg", "audio/mp4", "audio/flac"):
            raise Problem("UNSUPPORTED_AUDIO_TYPE")
        with self.lock, self.db() as db:
            old = db.execute("SELECT * FROM recordings WHERE device_id=? AND source_id=? AND sha256=?", (device, source, sha)).fetchone()
            stable = bool(re.fullmatch(r'd3200-sn-[a-f0-9]{64}', device))
            if not old and stable:
                old = db.execute("SELECT r.* FROM recording_sources s JOIN recordings r ON r.id=s.recording_id WHERE s.device_id=? AND s.source_id=? AND s.sha256=?", (device,source,sha)).fetchone()
            if not old and stable:
                # One-time legacy association requires a complete byte-identical file,
                # not a shared timestamp or a guessed device-wide address alias.
                candidates = db.execute("SELECT r.* FROM recordings r WHERE source_id=? AND sha256=? AND size=? AND mime=? AND stored=1 AND NOT EXISTS (SELECT 1 FROM recording_sources s WHERE s.source_id=r.source_id AND s.sha256=r.sha256 AND s.device_id<>?) ORDER BY created,id", (source,sha,size,mime,device)).fetchall()
                old = next((r for r in candidates if re.fullmatch(r'(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}',r['device_id'])),None)
                if old:
                    # Check durable storage too; a missing/corrupt archive must not count.
                    path = self.root / 'audio' / old['id']
                    if not path.is_file() or path.stat().st_size != size or digest(path) != sha:
                        raise Problem('ARCHIVED_AUDIO_INTEGRITY_FAILED',409)
                    db.execute('INSERT INTO recording_sources VALUES(?,?,?,?)',(device,source,sha,old['id']))
            if old:
                if old["size"] != size:
                    raise Problem("METADATA_CONFLICT", 409)
                uid = db.execute("SELECT id FROM uploads WHERE recording_id=?", (old["id"],)).fetchone()[0]
            else:
                # Reserve enough for both chunks and an assembled file, across pending uploads.
                reserved = db.execute("SELECT COALESCE(SUM(size),0) FROM recordings WHERE stored=0").fetchone()[0]
                if shutil.disk_usage(self.root).free < self.reserve_bytes + 2 * (reserved + size):
                    raise Problem("INSUFFICIENT_STORAGE", 507)
                rid, uid = uuid.uuid4().hex, uuid.uuid4().hex
                (self.root / "uploads" / uid).mkdir(mode=0o700)
                db.execute("INSERT INTO recordings(id,device_id,source_id,title,mime,size,sha256,created,recorded_at) VALUES(?,?,?,?,?,?,?,?,?)", (rid, device, source, title, mime, size, sha, time.time(), recorded_at))
                db.execute("INSERT INTO uploads VALUES(?,?)", (uid, rid))
        return self.upload_status(uid)

    def upload_status(self, uid):
        with self.db() as db:
            row = db.execute("SELECT r.*, u.id AS upload_id FROM uploads u JOIN recordings r ON u.recording_id=r.id WHERE u.id=?", (uid,)).fetchone()
            if not row:
                raise Problem("UPLOAD_NOT_FOUND", 404)
            return {"upload_id": uid, "recording_id": row["id"], "size": row["size"], "sha256": row["sha256"], "stored": bool(row["stored"]), "chunk_size": self.chunk_size,
                    "chunks": [dict(c) for c in db.execute("SELECT idx,sha256,size FROM chunks WHERE upload_id=? ORDER BY idx", (uid,))]}

    def put_chunk(self, uid, idx, payload, sha):
        sha_field(sha)
        with self.lock:
            status = self.upload_status(uid)
            count = math.ceil(status["size"] / self.chunk_size)
            integer(idx, 0, count - 1)
            expected_size = min(self.chunk_size, status["size"] - idx * self.chunk_size)
            if len(payload) != expected_size or hashlib.sha256(payload).hexdigest() != sha:
                raise Problem("CHUNK_CHECKSUM_MISMATCH", 422)
            existing = next((c for c in status["chunks"] if c["idx"] == idx), None)
            if existing and existing["sha256"] != sha:
                raise Problem("CHUNK_CONFLICT", 409)
            if status["stored"]:
                return status
            if shutil.disk_usage(self.root).free < self.reserve_bytes + len(payload):
                raise Problem("INSUFFICIENT_STORAGE", 507)
            # Rewriting identical data also repairs an incomplete filesystem write from a prior run.
            atomic_write(self.root / "uploads" / uid / str(idx), payload)
            with self.db() as db:
                db.execute("INSERT OR REPLACE INTO chunks VALUES(?,?,?,?)", (uid, idx, sha, len(payload)))
            return self.upload_status(uid)

    def complete(self, uid):
        with self.lock:
            status = self.upload_status(uid)
            rid = status["recording_id"]
            target = self.root / "audio" / rid
            if status["stored"]:
                if not target.exists() or digest(target) != status["sha256"]:
                    raise Problem("STORED_AUDIO_CORRUPT", 409)
                shutil.rmtree(self.root / "uploads" / uid, ignore_errors=True)
                return {**status, "verified": True}
            count = math.ceil(status["size"] / self.chunk_size)
            if len(status["chunks"]) != count:
                raise Problem("MISSING_CHUNKS", 409)
            if shutil.disk_usage(self.root).free < self.reserve_bytes + status["size"]:
                raise Problem("INSUFFICIENT_STORAGE", 507)
            tmp = target.with_suffix(".assembling")
            try:
                with tmp.open("wb") as out:
                    os.chmod(tmp, 0o600)
                    for c in status["chunks"]:
                        path = self.root / "uploads" / uid / str(c["idx"])
                        if not path.exists() or digest(path) != c["sha256"]:
                            raise Problem("CHUNK_CORRUPT", 422)
                        with path.open("rb") as inp:
                            shutil.copyfileobj(inp, out, 1024 * 1024)
                    out.flush()
                    os.fsync(out.fileno())
                if tmp.stat().st_size != status["size"] or digest(tmp) != status["sha256"]:
                    raise Problem("FILE_CHECKSUM_MISMATCH", 422)
                os.replace(tmp, target)
                fd = os.open(target.parent, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
                with self.db() as db:
                    db.execute("UPDATE recordings SET stored=1 WHERE id=?", (rid,))
                    for stage in STAGES:
                        db.execute("INSERT OR IGNORE INTO jobs(recording_id,stage,status,updated) VALUES(?,?,?,?)", (rid, stage, "pending", time.time()))
                shutil.rmtree(self.root / "uploads" / uid, ignore_errors=True)
            finally:
                tmp.unlink(missing_ok=True)
            return {**self.upload_status(uid), "verified": True}

    def result_path(self, rid, stage):
        self.recording(rid)
        if stage not in (*STAGES, "speakers"):
            raise Problem("INVALID_STAGE")
        return self.root / "results" / f"{rid}-{stage}.json"

    def save_result(self, rid, stage, value):
        atomic_write(self.result_path(rid, stage), json.dumps(value, ensure_ascii=False, allow_nan=False).encode())

    def result(self, rid, stage):
        p = self.result_path(rid, stage)
        return json.loads(p.read_text()) if p.exists() else None

    def set_job(self, rid, stage, status, error=None):
        with self.db() as db:
            db.execute("UPDATE jobs SET status=?,error=?,updated=?,attempts=attempts+? WHERE recording_id=? AND stage=?", (status, error, time.time(), int(status == "running"), rid, stage))

    def enqueue(self, rid, stage):
        if stage not in STAGES:
            raise Problem("INVALID_STAGE")
        with self.lock:
            r = self.recording(rid)
            if not r["stored"]:
                raise Problem("AUDIO_NOT_STORED", 409)
            statuses = {j["stage"]: j["status"] for j in r["jobs"]}
            if statuses[stage] in ("running", "queued", "completed"):
                return r
            previous = {"asr": None, "diarization": "asr", "summary": "diarization", "feishu": "summary"}[stage]
            if previous and statuses[previous] != "completed":
                raise Problem("PREVIOUS_STAGE_INCOMPLETE", 409)
            self.set_job(rid, stage, "queued")
            with self.db() as db:
                db.execute("UPDATE jobs SET attempts=0,retry_at=0 WHERE recording_id=? AND stage=?", (rid, stage))
            return self.recording(rid)

    def start_pipeline(self, rid):
        with self.lock:
            recording = self.recording(rid)
            if not recording['stored']:
                raise Problem('AUDIO_NOT_STORED', 409)
            with self.db() as db:
                db.execute('UPDATE recordings SET autoprocess=1 WHERE id=?', (rid,))
            for job in recording['jobs']:
                if job['status'] != 'completed':
                    return self.enqueue(rid, job['stage'])
            return self.recording(rid)

    def import_reference(self, rid, text):
        text = text_field(text, maximum=200000)
        with self.lock:
            recording = self.recording(rid)
            if not recording['stored']:
                raise Problem('AUDIO_NOT_STORED', 409)
            if recording['publications'] or any(j['status'] in ('running', 'queued', 'completed') for j in recording['jobs']):
                raise Problem('REFERENCE_IMPORT_REQUIRES_UNPROCESSED_RECORDING', 409)
            result = {'schema_version': 2, 'source': 'manual-reference-not-asr', 'text': text,
                      'segments': [{'id': i, 'text': line, 'words': [], 'start_ms': None, 'end_ms': None,
                                    'speaker_id': None} for i, line in enumerate(text.splitlines()) if line.strip()],
                      'speaker_accuracy_verified': False}
            self.save_result(rid, 'asr', result)
            self.save_result(rid, 'diarization', {'source': 'manual-reference-not-asr', 'speaker_ids': [],
                                               'accuracy_verified': False, 'note': '用户导入参考文字，未进行语音识别或说话人识别。'})
            self.set_job(rid, 'asr', 'completed')
            self.set_job(rid, 'diarization', 'completed')
            return self.recording(rid)

    def pause_pipeline(self, rid):
        with self.lock, self.db() as db:
            self.recording(rid)
            db.execute('UPDATE recordings SET autoprocess=0 WHERE id=?', (rid,))
            db.execute("UPDATE jobs SET status='interrupted',error='PAUSED_BY_USER' WHERE recording_id=? AND status='queued'", (rid,))
        return self.recording(rid)
