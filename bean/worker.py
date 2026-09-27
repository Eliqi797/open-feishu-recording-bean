import os
import errno
import threading
import time

from .settings import get as setting, Settings, scope

from .core import Problem, STAGES
from .feishu import publish
from .live import LiveStore
from .pipeline import summarize_resumable as summarize, transcribe_resumable as transcribe


class Worker:
    def __init__(self, store):
        self.store = store
        self.settings = Settings(store.root)
        self.live = LiveStore(store)
        self.stop = threading.Event()
        self.thread = None
        self.live_thread = None

    def start(self):
        self.thread = threading.Thread(target=self.run, name="bean-worker", daemon=True)
        self.thread.start()
        self.live_thread = threading.Thread(target=self.run_live, name="bean-live-worker", daemon=True)
        self.live_thread.start()

    def run(self):
        while not self.stop.is_set():
            if not self.once():
                self.stop.wait(1)

    def run_live(self):
        # Long archives must not hold up captions; each queue remains serialized.
        while not self.stop.is_set():
            if not self.live.once():
                self.stop.wait(0.2)

    def once(self):
        with scope(self.settings.snapshot()):
            return self._once()

    def _once(self):
        with self.store.lock, self.store.db() as db:
            row = db.execute("SELECT * FROM jobs WHERE status='queued' AND retry_at<=? ORDER BY updated LIMIT 1", (time.time(),)).fetchone()
            if not row:
                return False
            rid, stage = row["recording_id"], row["stage"]
            db.execute("UPDATE jobs SET status='running',attempts=attempts+1,error=NULL WHERE recording_id=? AND stage=?", (rid, stage))
        try:
            if stage == "asr":
                result = transcribe(self.store.root / "audio" / rid, self.store.root / "results" / (rid + "-work") / "asr",
                                    hotwords=[w.strip() for w in setting("ASR_HOTWORDS", "").split(",") if w.strip()])
            elif stage == "diarization":
                transcript = self.store.result(rid, "asr")
                words = [w for s in transcript["segments"] for w in s.get("words", [])]
                identified = [w for w in words if w.get('speaker_id') is not None]
                result = {"source": transcript.get("source", "unknown"), "speaker_ids": sorted({w['speaker_id'] for w in identified}),
                          "capability_status": 'fields_present' if words and len(identified) == len(words) else 'partial' if identified else 'unavailable',
                          "words_with_speaker": len(identified), "words_without_speaker": len(words) - len(identified),
                          "accuracy_verified": False, "sortformer_verified": False,
                          "note": "仅使用真实返回的匿名编号；缺失编号保留未知，不推断人数或姓名。独立说话人能力仍需验证。"}
            elif stage == "summary":
                result = summarize(self.store.result(rid, "asr"), self.store.root / "results" / (rid + "-work") / "summary")
            else:
                result = publish(self.store, rid)
            with self.store.lock:
                self.store.save_result(rid, stage, result)
                if stage=='summary' and result.get('title'):
                    with self.store.db() as db:db.execute('UPDATE recordings SET title=? WHERE id=?',(result['title'],rid))
                self.store.set_job(rid, stage, "completed")
                if self.store.recording(rid).get('autoprocess') and stage != STAGES[-1]:
                    self.store.enqueue(rid, STAGES[STAGES.index(stage) + 1])
        except Problem as e:
            transient = e.code in ("NVIDIA_RESOURCE_EXHAUSTED", "NVIDIA_UNAVAILABLE", "NVIDIA_DEADLINE_EXCEEDED", "PROVIDER_HTTP_429", "PROVIDER_HTTP_503", "PROVIDER_NETWORK_FAILURE")
            if stage in ("asr", "summary") and transient and row["attempts"] < 2:
                self.store.set_job(rid, stage, "queued", e.code)
                with self.store.db() as db:
                    db.execute("UPDATE jobs SET retry_at=? WHERE recording_id=? AND stage=?", (time.time() + 30 * 2**row["attempts"], rid, stage))
            else:
                self.store.set_job(rid, stage, "blocked" if e.status == 503 else "failed", e.code)
        except OSError as e:
            self.store.set_job(rid, stage, "failed", "INSUFFICIENT_STORAGE" if e.errno == errno.ENOSPC else "PROCESSING_IO_ERROR")
        except Exception:
            self.store.set_job(rid, stage, "failed", "UNEXPECTED_STAGE_ERROR")
        return True
