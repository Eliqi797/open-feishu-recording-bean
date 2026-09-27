"""Generate ignored iOS/Android build defaults for one private installation."""
from __future__ import annotations

import argparse
import base64
import os
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


def private_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".mobile-defaults-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def prepare(origin: str, token_file: Path) -> None:
    url = urlsplit(origin)
    if (url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment
            or url.path not in ("", "/") or origin != origin.strip()):
        raise ValueError("A plain HTTPS origin is required")
    token = token_file.read_text().strip()
    if len(token) < 16 or len(token) > 1024 or any(ch.isspace() for ch in token):
        raise ValueError("Private access token is missing or invalid")
    encoded_origin = base64.b64encode(origin.rstrip("/").encode()).decode()
    encoded_token = base64.b64encode(token.encode()).decode()
    private_write(ROOT / "ios/PersonalDefaults.local.xcconfig",
                  f"RECORDINGBEAN_PERSONAL_ORIGIN_B64 = {encoded_origin}\n"
                  f"RECORDINGBEAN_PERSONAL_TOKEN_B64 = {encoded_token}\n")
    private_write(ROOT / "android/personal-defaults.properties",
                  f"originBase64={encoded_origin}\ntokenBase64={encoded_token}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--origin", required=True)
    parser.add_argument("--token-file", type=Path, default=ROOT / "private/production-access-token")
    options = parser.parse_args()
    prepare(options.origin, options.token_file)
    print("Private mobile defaults prepared in ignored files; no credential values displayed.")
