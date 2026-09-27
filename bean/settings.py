"""Private per-deployment settings, redacted API views and per-job snapshots."""
import contextlib
import contextvars
import json
import os
import re
import threading
from urllib.parse import urlsplit
from .core import Problem, atomic_write

DEFAULTS = {
 'ASR_PROVIDER':'nvidia_parakeet', 'ASR_LANGUAGE':'zh-CN', 'ASR_CHUNK_SECONDS':'120',
 'ASR_RESPONSE_FORMAT':'verbose_json', 'ASR_BASE_URL':'', 'ASR_MODEL':'whisper-1', 'ASR_API_KEY':'', 'ASR_HOTWORDS':'',
 'NVIDIA_API_KEY':'', 'NVIDIA_MAX_SPEAKERS':'8', 'NVIDIA_TIMEOUT_SECONDS':'1800',
 'NVIDIA_SPEAKER_ZERO_POLICY':'unknown',
 'LLM_BASE_URL':'', 'LLM_MODEL':'', 'LLM_API_KEY':'',
 'FEISHU_AUTH_MODE':'user_token', 'FEISHU_APP_ID':'', 'FEISHU_APP_SECRET':'',
 'FEISHU_USER_ACCESS_TOKEN':'', 'FEISHU_EXPECTED_OPEN_ID':'', 'FEISHU_PERSONAL_CONFIRMED':'0',
 'FEISHU_CLI_PROFILE':'', 'FEISHU_FOLDER_TOKEN':'', 'FEISHU_DOCS_ORIGIN':'https://www.feishu.cn',
 'AUTO_PIPELINE':'0', 'DOCUMENT_TIMEZONE':'Asia/Shanghai',
}
SECRETS={'NVIDIA_API_KEY','ASR_API_KEY','LLM_API_KEY','FEISHU_APP_SECRET','FEISHU_USER_ACCESS_TOKEN'}
_context=contextvars.ContextVar('provider_configuration',default=None)

def get(name, default=None):
    snapshot=_context.get()
    if snapshot is not None and name in snapshot:return snapshot[name]
    return os.getenv(name, DEFAULTS.get(name,default))

@contextlib.contextmanager
def scope(snapshot):
    token=_context.set(snapshot)
    try:yield
    finally:_context.reset(token)

class Settings:
    def __init__(self, root):
        self.path=root/'provider-settings.json';self.lock=threading.RLock()
    def saved(self):
        if not self.path.exists():return {'revision':0,'values':{}}
        try:
            data=json.loads(self.path.read_text())
            if not isinstance(data['values'],dict) or not isinstance(data['revision'],int):raise ValueError()
            return data
        except (ValueError,KeyError):raise Problem('SETTINGS_FILE_INVALID',500) from None
    def snapshot(self):
        with self.lock:
            values={k:os.getenv(k,v) for k,v in DEFAULTS.items()}
            values.update(self.saved()['values']);return values
    def public(self):
        with self.lock:
            return self._public()
    def _public(self):
        values=self.snapshot()
        return {'revision':self.saved()['revision'], 'values':{k:v for k,v in values.items() if k not in SECRETS},
                'secrets_configured':{k:bool(values[k]) for k in SECRETS},
                'scope':'private_deployment', 'secret_storage':'server_private_file_0600'}
    def update(self, data):
        if not isinstance(data,dict) or set(data)-{'revision','values','clear_secrets'}:raise Problem('SETTINGS_INVALID')
        changes=data.get('values',{});clear=data.get('clear_secrets',[])
        if not isinstance(changes,dict) or set(changes)-DEFAULTS.keys() or not isinstance(clear,list) or any(not isinstance(k,str) or k not in SECRETS for k in clear):raise Problem('SETTINGS_FIELD_INVALID')
        with self.lock:
            old=self.saved()
            if data.get('revision')!=old['revision']:raise Problem('SETTINGS_CONFLICT_RELOAD',409)
            values=self.snapshot()
            for key,value in changes.items():
                if not isinstance(value,str) or len(value)>8192 or '\x00' in value:raise Problem('SETTINGS_VALUE_INVALID')
                if key in SECRETS and not value:continue # blank means preserve, never echo stored credentials
                values[key]=value.strip()
            for key in clear:values[key]=''
            before=self.snapshot()
            for endpoint,secret in [('ASR_BASE_URL','ASR_API_KEY'),('LLM_BASE_URL','LLM_API_KEY')]:
                if values[endpoint].rstrip('/')!=before[endpoint].rstrip('/') and before[secret] and values[secret] and not changes.get(secret, '').strip():
                    raise Problem('SETTINGS_KEY_REQUIRED_FOR_NEW_ENDPOINT')
            self.validate(values)
            atomic_write(self.path,json.dumps({'revision':old['revision']+1,'values':values}).encode())
            return self.public()
    @staticmethod
    def validate(v):
        from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
        try:ZoneInfo(v["DOCUMENT_TIMEZONE"])
        except (ZoneInfoNotFoundError,ValueError):raise Problem("SETTINGS_INVALID_DOCUMENT_TIMEZONE") from None
        enums={'ASR_RESPONSE_FORMAT':{'json','verbose_json'},'ASR_PROVIDER':{'nvidia_parakeet','nvidia_whisper','openai_compatible'},'FEISHU_AUTH_MODE':{'user_token','app','lark_cli'},'NVIDIA_SPEAKER_ZERO_POLICY':{'unknown','zero_based'},'AUTO_PIPELINE':{'0','1'},'FEISHU_PERSONAL_CONFIRMED':{'0','1'}}
        for key,choices in enums.items():
            if v[key] not in choices:raise Problem('SETTINGS_INVALID_'+key)
        for key,low,high in [('ASR_CHUNK_SECONDS',10,300),('NVIDIA_MAX_SPEAKERS',1,8),('NVIDIA_TIMEOUT_SECONDS',10,3600)]:
            if not v[key].isdigit() or not low<=int(v[key])<=high:raise Problem('SETTINGS_INVALID_'+key)
        for key in ['ASR_BASE_URL','LLM_BASE_URL','FEISHU_DOCS_ORIGIN']:
            if not v[key]:continue
            try:u=urlsplit(v[key]);port=u.port
            except ValueError:raise Problem('SETTINGS_INVALID_'+key) from None
            if u.scheme!='https' or not u.hostname or u.username or u.password or u.query or u.fragment:raise Problem('SETTINGS_HTTPS_REQUIRED_'+key)
            if key=='FEISHU_DOCS_ORIGIN' and (u.path not in ('','/') or not (u.hostname.endswith('.feishu.cn') or u.hostname.endswith('.larksuite.com'))):raise Problem('SETTINGS_INVALID_FEISHU_DOCS_ORIGIN')
        for key in ['FEISHU_CLI_PROFILE','ASR_LANGUAGE']:
            if v[key] and not re.fullmatch(r'[A-Za-z0-9_.-]{1,100}',v[key]):raise Problem('SETTINGS_INVALID_'+key)
