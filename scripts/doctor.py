"""Read-only environment inspection; prints presence/version, never credentials."""
import importlib.util
import json
import platform
import shutil
import subprocess
from pathlib import Path


def main():
    tools = {}
    for name in ("python3", "node", "git", "ffmpeg", "ffprobe", "hdc", "lark-cli"):
        tools[name] = shutil.which(name)
    apps = list(Path("/Applications").glob("*DevEco*")) + list(Path.home().joinpath("Applications").glob("*DevEco*"))
    sdks = []
    for app in apps:
        bundled = app / "Contents/sdk/default"
        hdc = bundled / "openharmony/toolchains/hdc"
        if hdc.is_file() and not tools["hdc"]:
            tools["hdc"] = str(hdc)
        metadata = bundled / "sdk-pkg.json"
        if metadata.is_file():
            sdks.append({"path": str(bundled), "metadata": json.loads(metadata.read_text())})
    result = {"platform": platform.platform(), "architecture": platform.machine(), "tools": tools,
              "deveco_app_paths": [str(p) for p in apps], "bundled_sdks": sdks,
              "free_disk_gib": round(shutil.disk_usage(Path.cwd()).free / 1024**3, 2),
              "riva_installed": importlib.util.find_spec("riva") is not None,
              "gates": {"device": "not_tested", "nvidia": "not_tested", "feishu_personal": "not_tested", "independent_backup": "not_tested"}}
    if tools["hdc"]:
        try:
            proc = subprocess.run([tools["hdc"], "list", "targets"], capture_output=True, text=True, timeout=15)
            result["hdc_devices_present"] = proc.returncode == 0 and bool(proc.stdout.strip() and "Empty" not in proc.stdout)
        except subprocess.TimeoutExpired:
            result["hdc_devices_present"] = None
            result["hdc_error"] = "timeout"
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
