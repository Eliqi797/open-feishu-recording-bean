"""Disposable MP3 derivatives for clients that cannot decode the archived Ogg file."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from .core import Problem, digest

MAX_FILE = 512 * 1024 * 1024
MAX_CACHE = 1024 * 1024 * 1024


def _prune(folder: Path, keep: Path | None = None, minimum_free: int = 0) -> None:
    files = sorted((p for p in folder.glob("*.mp3") if p.is_file() and p != keep),
                   key=lambda p: p.stat().st_mtime)
    size = sum(p.stat().st_size for p in folder.glob("*.mp3") if p.is_file())
    for path in files:
        if size <= MAX_CACHE and shutil.disk_usage(folder).free >= minimum_free:
            break
        length = path.stat().st_size
        path.unlink()
        size -= length


def compatible_audio(store, recording: dict) -> Path:
    """Called under the server playback lock; source audio is never modified."""
    folder = store.root / "playback-cache"
    folder.mkdir(mode=0o700, exist_ok=True)
    source = store.root / "audio" / recording["id"]
    destination = folder / (recording["id"] + "-" + recording["sha256"][:16] + ".mp3")
    if (destination.is_file() and 0 < destination.stat().st_size < MAX_FILE
            and destination.stat().st_mtime_ns >= source.stat().st_mtime_ns):
        os.utime(destination, None)
        return destination
    _prune(folder, minimum_free=store.reserve_bytes + MAX_FILE)
    if shutil.disk_usage(folder).free < store.reserve_bytes + MAX_FILE:
        raise Problem("PLAYBACK_DISK_LOW", 507)
    if digest(source) != recording["sha256"]:
        raise Problem("STORED_AUDIO_CORRUPT", 409)
    fd, name = tempfile.mkstemp(prefix=".playback-", dir=folder)
    os.close(fd)
    temporary = Path(name)
    try:
        command = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-threads", "1",
                   "-i", str(source), "-vn", "-ac", "1", "-b:a", "48k", "-fs", str(MAX_FILE),
                   "-f", "mp3", "-y", str(temporary)]
        try:
            result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    timeout=3600, check=False)
        except FileNotFoundError:
            raise Problem("PLAYBACK_FFMPEG_MISSING", 503) from None
        except subprocess.TimeoutExpired:
            raise Problem("PLAYBACK_CONVERSION_TIMEOUT", 503) from None
        if result.returncode != 0 or not 0 < temporary.stat().st_size < MAX_FILE:
            raise Problem("PLAYBACK_CONVERSION_FAILED", 422)
        os.replace(temporary, destination)
        _prune(folder, keep=destination)
        return destination
    finally:
        temporary.unlink(missing_ok=True)
