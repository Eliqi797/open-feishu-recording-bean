"""Conservative, non-disclosing review of every locally reachable Git revision.

Run after fetching all remote refs. A clean result is only a screening result,
not approval to publish: inspect rights, old branches, GitHub Actions, and files.
"""

from __future__ import annotations

import base64
import ipaddress
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTENT_RULES = {
    "credential pattern": re.compile(
        rb"nvapi-[A-Za-z0-9_-]{24,}|sk-[A-Za-z0-9_-]{24,}|"
        rb"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|"
        rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
    ),
    "absolute macOS home path": re.compile(rb"/Users/[A-Za-z0-9._-]+/"),
    "personal .xyz domain": re.compile(rb"\b[A-Za-z0-9.-]+\.xyz\b", re.I),
}
PRIVATE_PATHS = (
    ".codex/",
    "docs/history/",
    "docs/GCP_SERVICES.md",
    "docs/HUMAN_SETUP.md",
    "docs/VERIFICATION.md",
)
PRIVATE_NAMES = {
    ".env", "local.properties", "access-token", "production-access-token",
    "provider-settings.json", "app-preferences.json", "debug-cloud.json",
    "PersonalDefaults.local.xcconfig", "personal-defaults.properties",
}
PRIVATE_SUFFIXES = {".key", ".p12", ".jks", ".keystore", ".db", ".sqlite", ".sqlite3", ".wav", ".ogg", ".opus", ".mp3", ".m4a"}
IPV4 = re.compile(rb"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")


def git(*args: str) -> bytes:
    return subprocess.check_output(("git", *args), cwd=ROOT)


def known_local_values() -> set[bytes]:
    values: set[bytes] = set()
    env = ROOT / ".env"
    if env.is_file():
        for row in env.read_bytes().splitlines():
            if b"=" not in row or row.lstrip().startswith(b"#"):
                continue
            key, value = row.split(b"=", 1)
            value = value.strip().strip(b"\"'")
            if len(value) >= 16 and any(term in key.upper() for term in (b"KEY", b"SECRET", b"TOKEN")):
                values.add(value)
    token = ROOT / "private/production-access-token"
    if token.is_file():
        value = token.read_bytes().strip()
        if len(value) >= 16:
            values.add(value)
    return values | {base64.b64encode(value) for value in values}


def main() -> int:
    raw = git("rev-list", "--objects", "--all")
    names: dict[bytes, str] = {}
    for row in raw.splitlines():
        oid, _, path = row.partition(b" ")
        names[oid] = path.decode("utf-8", "replace") or "<unresolved blob>"
    if not names:
        print("No Git history found; cannot assess publication readiness.")
        return 2

    findings: dict[str, set[str]] = defaultdict(set)
    for path in set(names.values()):
        if path.startswith(PRIVATE_PATHS) or Path(path).name in PRIVATE_NAMES or Path(path).suffix in PRIVATE_SUFFIXES:
            findings["historical private/runtime path"].add(path)

    payload = b"\n".join(names) + b"\n"
    result = subprocess.run(("git", "cat-file", "--batch"), input=payload,
                            stdout=subprocess.PIPE, check=True, cwd=ROOT).stdout
    values = known_local_values()
    offset = 0
    blobs = 0
    for oid in names:
        end = result.index(b"\n", offset)
        header = result[offset:end].split()
        size = int(header[2])
        start = end + 1
        content = result[start:start + size]
        offset = start + size + 1
        if header[1] != b"blob":
            continue
        blobs += 1
        path = names[oid]
        # Binary cert and icon fixtures are not prose. Path checks still apply.
        if b"\0" in content[:2048]:
            continue
        for rule, pattern in CONTENT_RULES.items():
            if pattern.search(content):
                findings[rule].add(path)
        for line in content.splitlines():
            # Protocol compatibility advertises an okhttp version; it is not a host IP.
            if b"User-Agent: okhttp/" in line:
                continue
            for match in IPV4.finditer(line):
                try:
                    address = ipaddress.ip_address(match.group().decode())
                except ValueError:
                    continue
                if address.is_global:
                    findings["public IPv4 literal"].add(path)
        if any(value in content for value in values):
            findings["matches locally known private value"].add(path)

    print(f"Screened {blobs} historical Git blobs across all locally reachable refs.")
    if findings:
        for rule in sorted(findings):
            paths = sorted(findings[rule])
            print(f"REVIEW {rule}: {len(paths)} path(s)")
            for path in paths:
                print(f"  {path}")
        print("Publication review incomplete. No matched values were printed.")
        return 1
    print("No configured patterns found. Manual rights, history, and remote review still required.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
