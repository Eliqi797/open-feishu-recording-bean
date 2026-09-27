"""A user-token identity probe. Test document writes require an explicit CLI flag."""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bean.core import Problem, atomic_write
from bean.feishu import Feishu, compact
from bean.providers import load_env


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--create-test-document", action="store_true")
    parser.add_argument("--resume-report", type=Path, help="Reconcile an existing probe without creating another document")
    args = parser.parse_args()
    load_env(Path(".env"))
    out = args.resume_report.parent if args.resume_report else Path("private/probes") / f"{time.time_ns()}-feishu"
    out.mkdir(parents=True, mode=0o700, exist_ok=bool(args.resume_report))
    report = json.loads(args.resume_report.read_text()) if args.resume_report else {"status": "not_tested", "human_visibility": "not_tested", "browser_visibility": "not_tested"}
    client = Feishu()
    try:
        client.verify_identity()
        report["identity"] = "matches_confirmed_open_id"
        if args.create_test_document or args.resume_report:
            # Persist known document ID before any content write. Keep every probe for reconciliation.
            doc = report.get("document_id")
            if not doc:
                if args.resume_report:
                    raise Problem("FEISHU_CREATE_UNCERTAIN_RECONCILE_REQUIRED", 409)
                report["status"] = "creating"
                atomic_write(out / "report.json", json.dumps(report).encode())
                doc = client.create("录音豆接入测试 " + str(time.time_ns()))
                report.update(status="created", document_id=doc, url=client.last_document_url or "https://feishu.cn/docx/" + doc)
                atomic_write(out / "report.json", json.dumps(report).encode())
            text = "录音豆开发接入测试。仅测试文档写入与回读，不包含真实会议内容。"
            current = client.content(doc)
            if compact(text) not in compact(current):
                if report["status"] != "created":
                    raise Problem("FEISHU_WRITE_UNCERTAIN_RECONCILE_REQUIRED", 409)
                report["status"] = "writing"
                atomic_write(out / "report.json", json.dumps(report).encode())
                client.append(doc, text)
            if compact(client.content(doc)).count(compact(text)) != 1:
                raise Problem("FEISHU_READBACK_MISMATCH", 502)
            report.update(status="api_readback_verified", content_occurrences=1)
        else:
            report["status"] = "identity_verified"
    except Problem as e:
        report.update(status="blocked" if e.status == 503 else "failed", error=e.code)
    atomic_write(out / "report.json", json.dumps(report, ensure_ascii=False, indent=2).encode())
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["status"] in ("identity_verified", "api_readback_verified") else 1


if __name__ == "__main__":
    raise SystemExit(main())
