#!/usr/bin/env bash
# Requires Python 3. Default: preview only. Close Claude Desktop/Code before --apply.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import datetime
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import stat
import tempfile

p = argparse.ArgumentParser(description='Preview or remove selected local Claude metadata. No session history is deleted.')
p.add_argument('--apply', action='store_true', help='Write changes after creating backups')
p.add_argument('--root', action='append', default=[], help='Additional Claude config directory (repeatable; top level only)')
p.add_argument('--search', action='append', default=[], help='Additional directory tree to search (repeatable)')
p.add_argument('--no-search', action='store_true', help='Only inspect standard directories and --root')
args = p.parse_args()
home = Path.home()
roots = [home / '.claude', home / 'Library/Application Support/Claude',
         home / 'Library/Application Support/Claude-3p',
         Path('/Library/Application Support/Claude'),
         home / '.config/Claude', home / '.config/claude',
         Path(os.environ.get('XDG_CONFIG_HOME', str(home / '.config'))) / 'Claude']
for variable in ('APPDATA', 'LOCALAPPDATA'):
    if os.environ.get(variable):
        roots.extend(Path(os.environ[variable]) / name for name in ('Claude', 'Claude-3p'))
if os.environ.get('CLAUDE_CONFIG_DIR'):
    roots.append(Path(os.environ['CLAUDE_CONFIG_DIR']).expanduser())
roots.extend(Path(x).expanduser() for x in args.root)

# Explicit file families: do not scan project files, history, caches or VM images.
families = ('.claude.json', 'config.json', 'remote-control-state.json',
            'ant-device-registry.json', 'ant-did')
targets = {}
def collect(directory, names):
    if directory.is_symlink():
        raise RuntimeError(f'Symlink directory refused: {directory}')
    if not directory.exists():
        return
    for f in directory.iterdir():
        for name in names:
            if f.name == name or f.name.startswith(name + '.'):
                if f.is_symlink():
                    raise RuntimeError(f'Symlink file refused: {f}')
                if f.is_file():
                    targets[f.absolute()] = name
                break

# Full field names, never substring replacement inside arbitrary strings.
fields = {'machineID', 'userID', 'anonymousId', 'pairedDeviceId',
          'chromeExtension.pairedDeviceId', 'first_launch_at',
          'version_first_launch', 'lastKnownAccountUuid',
          'oauth:tokenCache', 'oauth:tokenCacheV2', 'telemetrySalt'}

prune = {'.git', '.hg', '.svn', 'node_modules', '.venv', 'venv', '__pycache__',
         'Cache', 'Caches', 'cache', '.cache', 'Code Cache', 'GPUCache',
         'vendor', 'Pods', '.Trash', 'Trash', 'claude-metadata-backups',
         'claude-code-sessions', 'local-agent-mode-sessions',
         'vm_bundles', 'claude-code-vm'}
scan_errors = []
def discover(base):
    if not base.is_dir() or base.is_symlink():
        raise RuntimeError(f'Invalid search directory: {base}')
    print(f'Search: {base}', flush=True)
    for directory, dirs, files in os.walk(base, followlinks=False,
                                          onerror=lambda e: scan_errors.append(str(e))):
        current = Path(directory)
        dirs[:] = [d for d in dirs if d not in prune and not (current / d).is_symlink()]
        if current.name == '.claude':
            dirs[:] = [d for d in dirs if d not in {'projects', 'sessions', 'debug', 'telemetry', 'file-history'}]
        if current.name.lower() in {'.claude', 'claude', 'claude-3p'} or any(
            name in files for name in ('ant-did', 'ant-device-registry.json', 'remote-control-state.json')
        ):
            collect(current, families)
        elif any(name == '.claude.json' or name.startswith('.claude.json.') for name in files):
            collect(current, ('.claude.json',))

def clean(obj, family, path=()):
    removed = []
    if isinstance(obj, dict):
        result = {}
        for key, value in obj.items():
            current = path + (key,)
            if key in fields or (family == 'config.json' and current == ('bootSideSessions', 'accountUuid')):
                removed.append('.'.join(current))
                continue
            if family == 'remote-control-state.json' and current == ('identities',):
                if value:
                    result[key] = {}
                    removed.append('identities (clear registrations)')
                else:
                    result[key] = value
                continue
            result[key], nested = clean(value, family, current)
            removed.extend(nested)
        return result, removed
    if isinstance(obj, list):
        result = []
        for i, value in enumerate(obj):
            value, nested = clean(value, family, path + (str(i),))
            result.append(value)
            removed.extend(nested)
        return result, removed
    return obj, removed

def unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError('Duplicate JSON key')
        obj[key] = value
    return obj

def invalid_constant(value):
    raise ValueError('Nonstandard JSON constant: ' + value)

try:
    collect(home, ('.claude.json',))
    for root in roots:
        collect(root, families)
    if not args.no_search:
        discover(home)
    for search in args.search:
        discover(Path(search).expanduser())
    for error in scan_errors[:5]:
        print('Search warning: ' + error)
    if len(scan_errors) > 5:
        print(f'Search warning: {len(scan_errors) - 5} more inaccessible directories; search coverage is incomplete.')
    plan = []
    journal_headers = {}
    for f, family in sorted(targets.items()):
        original = f.read_bytes()
        if family == 'ant-did':
            replacement, removed = None, ['remove device ID file']
        else:
            payload = original
            if f.name.endswith('.journal'):
                header = re.match(rb'([0-9a-f]{64}) ([0-9a-f]{64}) \.\n', original)
                base = f.with_name(f.name[:-len('.journal')])
                if not header or not base.is_file():
                    raise RuntimeError(f'Unsupported journal format: {f}')
                payload = original[header.end():]
                if (hashlib.sha256(payload).hexdigest().encode() != header[1] or
                    hashlib.sha256(base.read_bytes()).hexdigest().encode() != header[2]):
                    raise RuntimeError(f'Journal checksums do not match: {f}')
                journal_headers[f] = base
            try:
                obj = json.loads(payload, object_pairs_hook=unique_object, parse_constant=invalid_constant)
            except (ValueError, UnicodeError) as e:
                # Stop before any write, including when an old journal is not JSON.
                raise RuntimeError(f'Cannot safely parse {f}: {e}') from e
            if not isinstance(obj, dict):
                raise RuntimeError(f'Expected JSON object: {f}')
            if family == 'ant-device-registry.json':
                result, removed = {}, ['clear device registry'] if obj else []
            else:
                result, removed = clean(obj, family)
            replacement = (json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode()
        if removed:
            plan.append((f, original, replacement))
            print(f'{f}: ' + ', '.join(removed))
    replacements = {f: replacement for f, original, replacement in plan}
    for journal, base in journal_headers.items():
        # A journal header references both its JSON payload and the main config.
        payload = replacements.get(journal)
        if payload is None:
            if base not in replacements:
                continue
            raw = journal.read_bytes()
            payload = raw[re.match(rb'([0-9a-f]{64}) ([0-9a-f]{64}) \.\n', raw).end():]
            plan.append((journal, raw, payload))
        base_payload = replacements.get(base, base.read_bytes())
        replacements[journal] = (hashlib.sha256(payload).hexdigest() + ' ' +
                                 hashlib.sha256(base_payload).hexdigest() + ' .\n').encode() + payload
    plan = [(f, original, replacements.get(f, replacement)) for f, original, replacement in plan]
    print(f'Files to change: {len(plan)}')
    if not args.apply:
        print('Preview only. Close Claude Desktop and Claude Code, then rerun with --apply.')
        raise SystemExit(0)
    if not plan:
        raise SystemExit(0)

    # Backup contains credentials: private directory outside Claude configuration.
    backup_parent = home / '.local/state/claude-metadata-backups'
    backup_parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup = Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=backup_parent))
    for f, original, replacement in plan:
        if f.is_symlink() or f.read_bytes() != original:
            raise RuntimeError(f'File changed during preview: {f}; close Claude and retry')
        dest = backup / str(f).lstrip('/')
        dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with dest.open('xb') as stream:
            os.chmod(dest, 0o600)
            stream.write(original)
    print(f'Backup: {backup}', flush=True)

    for f, original, replacement in plan:
        if f.is_symlink() or f.read_bytes() != original:
            raise RuntimeError(f'File changed before write: {f}; stopped. Backup: {backup}')
        if replacement is None:
            f.unlink()
        else:
            mode = stat.S_IMODE(f.stat().st_mode)
            fd, temp = tempfile.mkstemp(prefix='.' + f.name + '-', dir=f.parent)
            try:
                with os.fdopen(fd, 'wb') as stream:
                    os.fchmod(stream.fileno(), mode)
                    stream.write(replacement)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temp, f)
            finally:
                if os.path.exists(temp):
                    os.unlink(temp)
    print('Done. Session history preserved. JSON formatting may have changed.')
except (OSError, RuntimeError, ValueError) as e:
    p.exit(1, f'ERROR: {e}\n')
PY
