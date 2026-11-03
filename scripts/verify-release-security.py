#!/usr/bin/env python3
"""Fail closed on private data in a release app; never echo matched values."""
import argparse
import io
import plistlib
import re
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath

PATTERNS = {
    'local user directory': re.compile(rb'/(?:Users|home)/[^/\s\x00`"<>]+/'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'),
    'GitHub token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'AWS access key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'API token': re.compile(rb'\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{32,}\b'),
}
MAX_FILE = 256 * 1024 * 1024
MAX_TOTAL = 1024 * 1024 * 1024
# Also cover checkouts outside a user home (for example a temporary build tree).
PROJECT_DIRECTORY = str(Path(__file__).resolve().parent.parent).encode()


def safe_framework_link(root, path):
    """Allow only Sparkle's standard versioned-framework aliases, never escapes."""
    framework = root / 'Contents/Frameworks/Sparkle.framework'
    aliases = {
        'Versions/Current': 'B',
        'Sparkle': 'Versions/Current/Sparkle',
        'Resources': 'Versions/Current/Resources',
        'Headers': 'Versions/Current/Headers',
        'Modules': 'Versions/Current/Modules',
        'XPCServices': 'Versions/Current/XPCServices',
        'PrivateHeaders': 'Versions/Current/PrivateHeaders',
        'Autoupdate': 'Versions/Current/Autoupdate',
        'Updater.app': 'Versions/Current/Updater.app',
    }
    try:
        relative = path.relative_to(framework).as_posix()
        if framework.is_symlink() or relative not in aliases:
            return False
        if str(path.readlink()) != aliases[relative]:
            return False
        resolved = path.resolve(strict=True)
        return resolved.is_relative_to(framework.resolve(strict=True))
    except (OSError, ValueError, RuntimeError):
        return False


def inspect_app(root):
    root = Path(root)
    errors = []
    total = 0
    checked = 0
    if root.is_symlink() or not root.is_dir():
        return ['app: expected a real application directory']
    try:
        metadata = plistlib.loads((root / 'Contents/Info.plist').read_bytes())
        if metadata.get('LingChongDaoBuildConfiguration') != 'release':
            errors.append('app: release build provenance is missing or not release')
        if metadata.get('CFBundleIdentifier') != 'local.lingchongdao.app':
            errors.append('app: unexpected application identity')
    except (OSError, ValueError, plistlib.InvalidFileException):
        errors.append('app: missing or invalid Info.plist')

    def inspect(name, data, depth=0):
        nonlocal total, checked
        checked += 1
        total += len(data)
        if total > MAX_TOTAL:
            raise ValueError('app: expanded content exceeds inspection limit')
        parts = PurePosixPath(name.split('!/')[-1]).parts
        for part in parts:
            lower = part.lower()
            if (lower == '.env' or lower.startswith('.env.') or lower in {'id_rsa', 'id_ed25519', '.ds_store'}
                    or lower.endswith(('.pem', '.p12', '.pfx', '.sqlite', '.sqlite3', '.db', '.har', '.log'))
                    or '.lingchongdao-backup-' in lower):
                errors.append(f'{name}: private/local artifact name')
                break
        if PROJECT_DIRECTORY in data:
            errors.append(f'{name}: build checkout path (value withheld)')
        for label, pattern in PATTERNS.items():
            if pattern.search(data):
                errors.append(f'{name}: possible {label} (value withheld)')
        if name.lower().endswith('.zip'):
            if depth >= 3:
                errors.append(f'{name}: archive nesting exceeds inspection limit')
                return
            try:
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    if len(archive.infolist()) > 10000:
                        raise ValueError('archive member limit')
                    seen = set()
                    for entry in archive.infolist():
                        path = PurePosixPath(entry.filename)
                        if (entry.filename in seen or path.is_absolute() or '..' in path.parts
                                or '\\' in entry.filename or stat.S_ISLNK(entry.external_attr >> 16)):
                            errors.append(f'{name}: unsafe archive member')
                            continue
                        seen.add(entry.filename)
                        if entry.is_dir():
                            continue
                        if entry.file_size > MAX_FILE or total + entry.file_size > MAX_TOTAL:
                            raise ValueError('archive size limit')
                        inspect(name + '!/' + entry.filename, archive.read(entry), depth + 1)
            except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
                errors.append(f'{name}: archive unreadable or exceeds inspection limit')

    try:
        for path in sorted(root.rglob('*')):
            name = path.relative_to(root).as_posix()
            if path.is_symlink():
                if not safe_framework_link(root, path):
                    errors.append(f'{name}: symlink is not allowed in the release app')
            elif path.is_file():
                if path.stat().st_size > MAX_FILE:
                    errors.append(f'{name}: file exceeds inspection limit')
                else:
                    inspect(name, path.read_bytes())
    except (OSError, ValueError):
        errors.append('app: cannot complete content inspection')
    if not checked:
        errors.append('app: no content inspected')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    errors = inspect_app(args.app)
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('PASS release security: release provenance, expanded app/ZIP content, private paths and artifact names')
    return 0


if __name__ == '__main__':
    sys.exit(main())
