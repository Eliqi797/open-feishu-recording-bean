"""Check the Git index before commit. Reports paths/rules, never matched secrets."""
import re
import base64
import ipaddress
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_CERTS = {'tests/fixtures/d3200-public-leaf.der', 'tests/fixtures/d3200-public-leaf.pem'}
FORBIDDEN_PARTS = {'private', 'data', '.venv', '.codex', '.idea', '.cert', 'certs',
                   'references', 'artifacts', 'build', '.hvigor', 'oh_modules', 'node_modules', '__pycache__'}
FORBIDDEN_NAMES = {'local.properties', 'provider-settings.json', 'debug-cloud.json',
                   'app-preferences.json', 'access-token', 'production-access-token', '.envrc',
                   'PersonalDefaults.local.xcconfig', 'personal-defaults.properties'}
FORBIDDEN_SUFFIXES = {'.p12', '.p7b', '.cer', '.csr', '.key', '.pem', '.jks', '.keystore',
                      '.hap', '.app', '.db', '.sqlite', '.sqlite3', '.wav', '.ogg', '.opus',
                      '.mp3', '.m4a', '.log', '.zip', '.gz'}
PATTERN = re.compile(rb'nvapi-[A-Za-z0-9_\-]{24,}|sk-[A-Za-z0-9_\-]{24,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----')
PERSONAL_CONTEXT = re.compile(rb'/Users/[A-Za-z0-9._-]+/|\b[A-Za-z0-9.-]+\.xyz\b', re.I)
IPV4 = re.compile(rb'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def local_secrets():
    values = set()
    token = ROOT / 'private/production-access-token'
    if token.is_file():
        value = token.read_bytes().strip()
        if len(value) >= 16: values.add(value)
    env = ROOT / '.env'
    if env.is_file():
        for row in env.read_text().splitlines():
            if '=' not in row or row.lstrip().startswith('#'): continue
            key, value = row.split('=', 1)
            value = value.strip().strip('\"\'').encode()
            if any(term in key.upper() for term in ('KEY', 'SECRET', 'TOKEN')) and len(value) >= 16:
                values.add(value)
    return values | {base64.b64encode(value) for value in values}

def main():
    paths = [p.decode() for p in git('ls-files', '-z').split(b'\0') if p]
    if not paths:
        print('No staged/tracked files to inspect. Stage the intended source files first.')
        return 2
    known = local_secrets()
    problems = []
    for name in paths:
        p = Path(name)
        data = git('show', ':' + name)
        if any(part in FORBIDDEN_PARTS for part in p.parts) or p.name in FORBIDDEN_NAMES:
            problems.append((name, 'private/runtime path'))
        if p.name.startswith('.env') and p.name != '.env.example':
            problems.append((name, 'environment file'))
        if p.suffix in FORBIDDEN_SUFFIXES and name not in PUBLIC_CERTS:
            problems.append((name, 'credential/runtime/build artifact'))
        if PATTERN.search(data) or any(value in data for value in known):
            problems.append((name, 'secret content'))
        if PERSONAL_CONTEXT.search(data):
            problems.append((name, 'personal hostname or local path'))
        if b'\0' not in data[:2048]:
            for line in data.splitlines():
                if b'User-Agent: okhttp/' in line:
                    continue
                public_ip = False
                for match in IPV4.finditer(line):
                    try:
                        public_ip = ipaddress.ip_address(match.group().decode()).is_global
                    except ValueError:
                        continue
                    if public_ip:
                        break
                if public_ip:
                    problems.append((name, 'public IPv4 literal'))
                    break
        if p.suffix == '.json5' and re.search(rb'"(?:storePassword|keyPassword|profile|certpath)"\s*:', data):
            problems.append((name, 'personal signing configuration'))
        if name.endswith('.pem') and name in PUBLIC_CERTS:
            if b'-----BEGIN CERTIFICATE-----' not in data or b'PRIVATE KEY' in data:
                problems.append((name, 'not a public certificate fixture'))
    if problems:
        for name, rule in problems:
            print(f'BLOCKED {name}: {rule}')
        return 1
    print(f'Checked {len(paths)} index files: no prohibited paths or detected secrets.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
