"""Explicit live probe. Writes transcript/raw audio results only under private/."""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bean.core import Problem, atomic_write
from bean.providers import load_env, transcribe


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("--mode", choices=("baseline", "speakers", "hotwords", "whisper"), default="baseline")
    parser.add_argument("--function-id", help="Optional override after verifying NVIDIA's current official API example")
    parser.add_argument("--hotword", action="append", default=[])
    args = parser.parse_args()
    if not args.audio.is_file():
        parser.error("音频文件不存在")
    load_env(Path(".env"))
    out = Path("private/probes") / f"{time.time_ns()}-{args.mode}"
    out.mkdir(parents=True, mode=0o700)
    report = {"mode": args.mode, "status": "not_tested", "speaker_accuracy": "not_tested", "hotword_effect": "not_tested", "long_audio_limit": "not_tested"}
    try:
        result = transcribe(args.audio.resolve(), out / "raw.json", diarization=args.mode == "speakers",
                            hotwords=args.hotword if args.mode == "hotwords" else None, function_id=args.function_id, whisper=args.mode == "whisper")
        atomic_write(out / "transcript.json", json.dumps(result, ensure_ascii=False).encode())
        report.update(status="response_received", metrics=result["metrics"], speaker_tags_observed=result["speaker_tags_observed"],
                      words_with_timestamps=sum(w["start_ms"] is not None and w["end_ms"] is not None for s in result["segments"] for w in s["words"]),
                      human_audio_comparison="required")
    except Problem as e:
        report.update(status="blocked" if e.status == 503 else "failed", error=e.code)
    atomic_write(out / "report.json", json.dumps(report, ensure_ascii=False, indent=2).encode())
    print(json.dumps({**report, "evidence_directory": str(out)}, ensure_ascii=False, indent=2))
    return 0 if report["status"] == "response_received" else 1


if __name__ == "__main__":
    raise SystemExit(main())
