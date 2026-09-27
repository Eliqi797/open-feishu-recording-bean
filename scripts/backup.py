"""Consistent stopped-service backup. Destination must be new; never overwrites."""
import argparse
import fcntl
import json
import os
import re
import shutil
import sqlite3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bean.core import Problem, atomic_write, digest


def verify(root):
    manifest = json.loads((root / "manifest.json").read_text())
    if manifest.get("version") != 1:
        raise Problem("BACKUP_MANIFEST_VERSION")
    listed = [entry['path'] for entry in manifest['files']]
    actual = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p.name != 'manifest.json'}
    if len(listed) != len(set(listed)) or set(listed) != actual or 'state.sqlite3' not in listed:
        raise Problem('BACKUP_FILE_SET_MISMATCH')
    if any(p.is_symlink() for p in root.rglob('*')):
        raise Problem('BACKUP_PATH_INVALID')
    for entry in manifest["files"]:
        rel = entry["path"]
        if not re.fullmatch(r"state\.sqlite3|(?:audio|results|uploads)/[a-zA-Z0-9_.\-/]+", rel) or ".." in Path(rel).parts:
            raise Problem("BACKUP_PATH_INVALID")
        path = root / rel
        if not path.resolve().is_relative_to(root.resolve()) or path.is_symlink():
            raise Problem("BACKUP_PATH_INVALID")
        if not path.is_file() or path.stat().st_size != entry["size"] or digest(path) != entry["sha256"]:
            raise Problem("BACKUP_CHECKSUM_MISMATCH")
    con = sqlite3.connect(root / "state.sqlite3")
    try:
        if con.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise Problem("BACKUP_DATABASE_CORRUPT")
        for rid, sha in con.execute("SELECT id,sha256 FROM recordings WHERE stored=1"):
            if not re.fullmatch(r"[a-f0-9]{32}", rid) or digest(root / "audio" / rid) != sha:
                raise Problem("BACKUP_AUDIO_MISMATCH")
    finally:
        con.close()
    return manifest


def backup(source, dest):
    source, dest = source.resolve(), dest.resolve()
    if dest.exists() or dest.is_relative_to(source):
        raise Problem("BACKUP_DESTINATION_MUST_BE_NEW_AND_OUTSIDE_SOURCE")
    if not (source / "state.sqlite3").is_file():
        raise Problem("SOURCE_DATABASE_NOT_FOUND")
    with (source / "server.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Problem("STOP_SERVER_BEFORE_BACKUP") from None
        dest.mkdir(parents=True, mode=0o700)
        src = sqlite3.connect(source / "state.sqlite3")
        dst = sqlite3.connect(dest / "state.sqlite3")
        try:
            src.backup(dst)
        finally:
            src.close()
            dst.close()
        for name in ("audio", "results", "uploads"):
            shutil.copytree(source / name, dest / name)
        entries = [{"path": str(p.relative_to(dest)), "size": p.stat().st_size, "sha256": digest(p)} for p in sorted(dest.rglob("*")) if p.is_file()]
        atomic_write(dest / "manifest.json", json.dumps({"version": 1, "files": entries, "independent_storage_verified": False}, indent=2).encode())
        verify(dest)
        atomic_write(source / 'last-backup.json', json.dumps({'created': time.time(), 'files': len(entries),
                     'checksums_verified': True, 'independent_storage_verified': False}).encode())
        # A root-run backup must leave its report readable by the service account.
        if os.geteuid() == 0:
            owner = source.stat()
            os.chown(source / 'last-backup.json', owner.st_uid, owner.st_gid)
    return len(entries)


def restore(source, dest):
    verify(source)
    if dest.exists():
        raise Problem("RESTORE_DESTINATION_MUST_BE_NEW")
    shutil.copytree(source, dest)
    verify(dest)
    # Access tokens, .env and sessions are deliberately not backed up with recordings.


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=("backup", "verify", "restore"))
    p.add_argument("source", type=Path)
    p.add_argument("destination", type=Path, nargs="?")
    args = p.parse_args()
    if args.action != "verify" and args.destination is None:
        p.error("此操作需要新目标目录")
    try:
        if args.action == "verify":
            verify(args.source)
        elif args.action == "backup":
            backup(args.source, args.destination)
        else:
            restore(args.source, args.destination)
        print("文件校验通过；独立存储及实际恢复使用仍需另外验收。")
    except Problem as e:
        p.exit(1, e.code + "\n")
