from __future__ import annotations

import hashlib
import os
import re
import json
import shutil
import subprocess
import xml.etree.ElementTree as ET
from html import escape
from urllib.parse import quote

from .settings import get as setting

from .core import Problem
from .providers import configured, request_json

BASE = "https://open.feishu.cn/open-apis"


class Feishu:
    def __init__(self):
        self.cli_mode = setting("FEISHU_AUTH_MODE", "user_token") == "lark_cli"
        self.last_document_url = None
        self.app_token = None

    def cli(self, args, content=None):
        executable = shutil.which("lark-cli")
        if not executable:
            raise Problem("FEISHU_CLI_NOT_INSTALLED", 503)
        profile = setting("FEISHU_CLI_PROFILE", "")
        env = dict(os.environ, LARKSUITE_CLI_NO_UPDATE_NOTIFIER="1", LARKSUITE_CLI_NO_SKILLS_NOTIFIER="1")
        try:
            proc = subprocess.run([executable, *(["--profile", profile] if profile else []), *args, "--as", "user"],
                                  input=content, capture_output=True, text=True, timeout=90, env=env)
        except subprocess.TimeoutExpired:
            # A write may have succeeded remotely; the publication journal must reconcile it.
            raise Problem("FEISHU_CLI_RESPONSE_UNCERTAIN", 502) from None
        except OSError:
            raise Problem("FEISHU_CLI_UNAVAILABLE", 503) from None
        if proc.returncode:
            # CLI stderr can contain private content or authorization URLs; never expose it in HTTP errors.
            raise Problem("FEISHU_CLI_EXIT_" + str(proc.returncode), 502)
        try:
            result = json.loads(proc.stdout)
        except ValueError:
            raise Problem("FEISHU_CLI_INVALID_RESPONSE", 502) from None
        if not isinstance(result, dict) or result.get("ok") is not True:
            raise Problem("FEISHU_CLI_INVALID_RESPONSE", 502)
        if result.get("identity") != "user":
            raise Problem("FEISHU_IDENTITY_MISMATCH", 403)
        data = result.get("data")
        if not isinstance(data, dict) or data.get("result") in ("partial_success", "failed"):
            raise Problem("FEISHU_CLI_PARTIAL_OR_INVALID_RESPONSE", 502)
        return data

    def call(self, method, path, data=None):
        if self.cli_mode:
            # The user-info endpoint has no docs shortcut. Document operations below use typed shortcuts.
            if method != "GET" or path != "/authen/v1/user_info":
                raise Problem("FEISHU_CLI_UNSUPPORTED_CALL", 500)
            return self.cli(["api", "GET", "/open-apis" + path])
        token=configured("FEISHU_USER_ACCESS_TOKEN") if setting('FEISHU_AUTH_MODE')!='app' else self.tenant_token()
        result = request_json(BASE + path, token, data, method)
        if result.get("code") != 0:
            raise Problem("FEISHU_CODE_" + str(result.get("code", "UNKNOWN")), 502)
        return result.get("data", {})

    def tenant_token(self):
        if self.app_token:return self.app_token
        result=request_json(BASE+'/auth/v3/tenant_access_token/internal','',{'app_id':configured('FEISHU_APP_ID'),'app_secret':configured('FEISHU_APP_SECRET')})
        if result.get('code')!=0 or not result.get('tenant_access_token'):raise Problem('FEISHU_APP_AUTH_FAILED',502)
        self.app_token=result['tenant_access_token'];return self.app_token

    def verify_identity(self):
        if setting("FEISHU_PERSONAL_CONFIRMED") != "1":
            raise Problem("FEISHU_PERSONAL_IDENTITY_NOT_CONFIRMED", 503)
        if setting("FEISHU_AUTH_MODE")=="app":
            self.tenant_token();return
        expected = configured("FEISHU_EXPECTED_OPEN_ID")
        user = self.call("GET", "/authen/v1/user_info")
        if user.get("open_id") != expected:
            raise Problem("FEISHU_IDENTITY_MISMATCH", 403)

    def create(self, title):
        if self.cli_mode:
            args = ["docs", "+create", "--content", "-"]
            if setting("FEISHU_FOLDER_TOKEN"):
                args += ["--parent-token", configured("FEISHU_FOLDER_TOKEN")]
            doc = self.cli(args, "<title>" + escape(title) + "</title>")["document"]
            self.last_document_url = doc.get("url")
            return doc["document_id"]
        body = {"title": title}
        if setting("FEISHU_FOLDER_TOKEN"):
            body["folder_token"] = configured("FEISHU_FOLDER_TOKEN")
        return self.call("POST", "/docx/v1/documents", body)["document"]["document_id"]

    def content(self, doc):
        if self.cli_mode:
            data = self.cli(["docs", "+fetch", "--doc", doc, "--doc-format", "xml"])
            try:
                root = ET.fromstring("<root>" + data["document"]["content"] + "</root>")
                return "".join(root.itertext())
            except (ET.ParseError, KeyError, TypeError):
                raise Problem("FEISHU_CLI_INVALID_DOCUMENT", 502) from None
        return self.call("GET", f"/docx/v1/documents/{quote(doc, safe='')}/raw_content")["content"]

    def title(self, doc):
        if self.cli_mode:
            data = self.cli(['docs', '+fetch', '--doc', doc, '--doc-format', 'xml'])
            try:
                return ''.join(ET.fromstring('<root>' + data['document']['content'] + '</root>').find('title').itertext())
            except (KeyError, ET.ParseError, AttributeError):
                raise Problem('FEISHU_DOCUMENT_TITLE_UNAVAILABLE', 502) from None
        return self.call('GET', f'/docx/v1/documents/{quote(doc, safe="")}')['document']['title']

    def append(self, doc, text):
        if self.cli_mode:
            content = styled_xml(text)
            return self.cli(["docs", "+update", "--doc", doc, "--command", "append", "--content", "-"], content)
        # One bounded batch, not a partial multi-request append, makes readback reconciliation possible.
        children=[]
        for kind,line in document_lines(text):
            if kind=='todo':
                # One checkbox per task, including long task text, never one per text run.
                children.append({'block_type':17,'todo':{'style':{'done':False},'elements':[
                    {'text_run':{'content':line[start:start+1200]}} for start in range(0,len(line),1200)]}})
            else:
                for start in range(0,len(line),1200):
                    children.append({'block_type':4 if kind=='heading2' else 2,kind:{'elements':[{'text_run':{'content':line[start:start+1200]}}]}})

        result={}
        for offset in range(0,len(children),50):result=self.call("POST", f"/docx/v1/documents/{quote(doc, safe='')}/blocks/{quote(doc, safe='')}/children", {"children": children[offset:offset+50], "index": -1})
        return result


def compact(text):
    return re.sub(r"\s+", "", text)


def remaining_append(expected, current, title):
    """Resume only an exact prefix of our immutable payload. Any edit requires human reconciliation."""
    seen = compact(current)
    heading = compact(title)
    if seen.startswith(heading):
        seen = seen[len(heading):]
    if not compact(expected).startswith(seen):
        raise Problem('FEISHU_WRITE_UNCERTAIN_RECONCILE_REQUIRED', 409)
    if not seen:
        return expected
    count = 0
    for i, char in enumerate(expected):
        if not char.isspace():
            count += 1
        if count == len(seen):
            return expected[i + 1:]
    return ''

SECTION_HEADINGS={'录音信息','内容摘要','结论','待办事项','待确认事项','转写原文','识别说明','关联文档','记录索引'}
def document_lines(text):
    """Keep visible text immutable; only turn generated action headings into native todos."""
    lines=text.splitlines();section='';new_item=False
    for index,line in enumerate(lines):
        if not line:
            new_item=True;continue
        if line in SECTION_HEADINGS:
            section=line;new_item=True;yield 'heading2',line;continue
        has_action_details=(index+2<len(lines) and lines[index+1].startswith('责任人：') and lines[index+2].startswith('依据：'))
        kind='todo' if has_action_details or (section=='待办事项' and new_item and not line.startswith(('责任人：','依据：'))) else 'text'
        new_item=False;yield kind,line

def styled_xml(text):
    out=[]
    for kind,line in document_lines(text):
        if kind=='todo':out.append('<checkbox done="false">'+escape(line)+'</checkbox>')
        elif kind=='heading2':out.append('<h2>'+escape(line)+'</h2>')
        elif line.startswith(('开始录制：','录音时长：','音频大小：','文字来源：')):
            label,body=line.split('：',1);out.append('<p><b>'+escape(label+'：')+'</b>'+escape(body)+'</p>')
        elif re.match(r'^\[\d+:\d+:\d+\]',line):out.append('<p><b>'+escape(line)+'</b></p>')
        elif line.startswith(('记录索引：','记录校验 ')):out.append('<p><span text-color="gray">'+escape(line)+'</span></p>')
        else:out.append('<p>'+escape(line)+'</p>')
    return ''.join(out)

def duration_label(ms):
    if ms is None:return '未知'
    seconds=int(ms/1000);return f'{seconds//3600:02d}:{seconds//60%60:02d}:{seconds%60:02d}'

def render(recording, transcript, summary):
    from datetime import datetime
    from zoneinfo import ZoneInfo
    rid=recording['id'];origin=setting('PUBLIC_ORIGIN','').rstrip('/')
    if origin.startswith('https://'):playback=f"回听原音（需登录）：{origin}/?recording={rid}"
    elif setting('FEISHU_LOCAL_PREVIEW')=='1':playback='本地联调测试：回听尚未上线；音频保存在本机受保护工作台。'
    else:raise Problem('PUBLIC_ORIGIN_REQUIRES_HTTPS',503)
    started=recording.get('recorded_at');zone=setting('DOCUMENT_TIMEZONE','Asia/Shanghai')
    date=datetime.fromtimestamp(started,ZoneInfo(zone)).strftime('%Y-%m-%d %H:%M:%S')+' · '+zone if started else '未知（未提供设备录制时间）'
    duration=max((c.get('end_ms',0) for c in transcript.get('chunks',[])),default=0) or transcript.get('duration_ms')
    main='录音信息\n开始录制：'+date+'\n录音时长：'+duration_label(duration)+'\n音频大小：'+(f"{recording['size']/1048576:.1f} MB" if recording.get('size') else '未知')+'\n'+playback+'\n\n'
    if transcript.get('source')=='manual-reference-not-asr':main+='文字来源：人工导入的参考文字，不是语音识别结果。\n'
    gaps=transcript.get('coverage',{}).get('unrecognized_chunks',[])
    if gaps:main+='转写不完整：部分时段没有识别文字，摘要仅覆盖已识别内容，具体范围见文末识别说明。\n'
    main+='\n内容摘要\n'+summary['summary']+'\n'
    if summary['decisions']:main+='\n结论\n'+'\n'.join(summary['decisions'])+'\n'
    if summary['actions']:
        main+='\n待办事项\n'
        for action in summary['actions']:
            main+=action['task']+'\n责任人：'+(action.get('owner') or '待确认')+' · 日期：'+(action.get('due_date') or '待确认')+'\n依据：'+action['evidence']+'\n\n'
    concerns=[v for v in summary['uncertainties'] if not v.startswith('以下时段没有识别文字')]
    if concerns:main+='\n待确认事项\n'+'\n\n'.join(concerns)+'\n'
    main+='\n转写原文\n'
    for segment in transcript['segments']:
        main+='['+duration_label(segment.get('start_ms'))+'] 片段 '+str(segment['id']+1)+'\n'+segment['text']+'\n\n'
    main+='识别说明\n'
    if gaps:
        merged=[]
        for gap in gaps:
            if merged and merged[-1][1]==gap['start_ms']:merged[-1][1]=gap['end_ms']
            else:merged.append([gap['start_ms'],gap['end_ms']])
        main+='未识别时段：'+'、'.join(duration_label(a)+'–'+duration_label(b) for a,b in merged)+'。未返回文字不等于静音，请结合原音核对。\n'
    words=[w for seg in transcript['segments'] for w in seg.get('words',[])]
    main+=('说话人区分未完整获得，缺失信息保留未知。' if not words or any(w.get('speaker_id') is None for w in words) else '原始结果保留分段内匿名说话人编号，未跨分段合并身份。')+'不据此推断人数、姓名或待办责任人。\nAI 整理结果，请核对原音。'
    # Preserve complete text. New sections are split before the API block limit.
    parts=[]
    while main:
        cut=min(12000,len(main))
        if cut<len(main):
            newline=main.rfind('\n',0,cut)
            if newline>0:cut=newline+1
        title=summary.get('title') or recording['title']
        parts.append((title[:100]+('' if not parts else ' · 转写续文 '+str(len(parts))),main[:cut]));main=main[cut:]
    if len(parts)>500:raise Problem('FEISHU_TOO_MANY_DOCUMENT_PARTS',422)
    return parts


def publish(store, rid, client=None):
    client = client or Feishu()
    client.verify_identity()
    r = store.recording(rid)
    transcript, summary = store.result(rid, "asr"), store.result(rid, "summary")
    parts = render(r, transcript, summary)
    with store.db() as db:
        for index, (title, body) in enumerate(parts):
            sha = hashlib.sha256(body.encode()).hexdigest()
            old = db.execute("SELECT * FROM publications WHERE recording_id=? AND part=?", (rid, index)).fetchone()
            if old and old["content_hash"] != sha:
                raise Problem("PUBLICATION_CONTENT_CHANGED", 409)
            db.execute("INSERT OR IGNORE INTO publications(recording_id,part,status,content_hash,title) VALUES(?,?,?,?,?)", (rid, index, "pending", sha, title))

    def update(index, **fields):
        with store.db() as db:
            db.execute("UPDATE publications SET " + ",".join(k + "=?" for k in fields) + " WHERE recording_id=? AND part=?", (*fields.values(), rid, index))

    # Create every part before linking the main document. A lost create response is not blindly retried.
    for index, (title, _) in enumerate(parts):
        p = store.recording(rid)["publications"][index]
        if p["document_id"]:
            continue
        if p["status"] == "creating":
            raise Problem("FEISHU_CREATE_UNCERTAIN_RECONCILE_REQUIRED", 409)
        update(index, status="creating", error=None)
        try:
            doc = client.create(title)
            if not re.fullmatch(r"[A-Za-z0-9_-]+", doc):
                raise Problem("FEISHU_INVALID_DOCUMENT_ID", 502)
            update(index, document_id=doc, status="created")
        except Exception:
            update(index, error="CREATE_RESPONSE_UNCERTAIN")
            raise

    pubs = store.recording(rid)["publications"]
    links = "\n".join(f"{p['title']} {setting('FEISHU_DOCS_ORIGIN').rstrip('/')}/docx/{p['document_id']}" for p in pubs[1:])
    for index, (_, body) in enumerate(parts):
        p = store.recording(rid)["publications"][index]
        if index == 0 and links:
            body += "\n\n关联文档\n" + links
        marker = f"记录索引：{rid[:8]}-{index}"
        expected = body + "\n" + marker
        current = client.content(p["document_id"])
        if compact(expected) in compact(current):
            update(index, status="verified", error=None)
            continue
        if p["status"] == "verified":
            raise Problem("FEISHU_WRITE_UNCERTAIN_RECONCILE_REQUIRED", 409)
        remaining = expected
        if p["status"] == "writing":
            remaining = remaining_append(expected, current, p['title'])
        update(index, status="writing", error=None)
        if remaining:
            client.append(p["document_id"], remaining)
        readback = client.content(p["document_id"])
        if compact(expected) not in compact(readback):
            raise Problem("FEISHU_READBACK_MISMATCH", 502)
        update(index, status="verified", error=None)
    return {"documents": store.recording(rid)["publications"], "api_readback_verified": True, "human_visibility_verified": False}


def reconcile_document(store, rid, part, document_id, client=None):
    """Bind an explicitly selected existing document after an ambiguous create response."""
    if not isinstance(document_id, str) or not re.fullmatch(r'[A-Za-z0-9_-]{8,100}', document_id):
        raise Problem('FEISHU_INVALID_DOCUMENT_ID')
    client = client or Feishu()
    client.verify_identity()
    with store.lock:
        recording = store.recording(rid)
        if any(j['status'] in ('running', 'queued') for j in recording['jobs']):
            raise Problem('PAUSE_PIPELINE_BEFORE_RECONCILE', 409)
        rows = [p for p in recording['publications'] if p['part'] == part]
        if not rows or rows[0]['status'] != 'creating' or rows[0]['document_id']:
            raise Problem('PUBLICATION_NOT_AWAITING_RECONCILE', 409)
        expected = rows[0]['title']
        if client.title(document_id) != expected:
            raise Problem('FEISHU_RECONCILE_TITLE_MISMATCH', 409)
        content = compact(client.content(document_id))
        if content not in ('', compact(expected)):
            raise Problem('FEISHU_RECONCILE_DOCUMENT_NOT_EMPTY', 409)
        with store.db() as db:
            db.execute("UPDATE publications SET document_id=?,status='created',error=NULL WHERE recording_id=? AND part=?", (document_id, rid, part))
    return store.recording(rid)
