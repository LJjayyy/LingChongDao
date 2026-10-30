#!/bin/bash
# Build a complete local marketplace, without installing it or changing trust.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$project_dir/dist/codex-plugin"
plugin_icon=''
if [[ "$#" -gt 0 && "$1" != "--icon" ]]; then output_dir="$1"; shift; fi
if [[ "$#" -eq 2 && "$1" == "--icon" ]]; then
  plugin_icon="$2"
  [[ -s "$plugin_icon" ]] || { echo "Plugin icon not found: $plugin_icon" >&2; exit 1; }
elif [[ "$#" -ne 0 ]]; then
  echo "Usage: scripts/build-codex-plugin.sh [OUTPUT_DIRECTORY] [--icon PATH]" >&2
  exit 2
fi
source_dir="$project_dir/integrations/codex-plugin"
app_dir="$project_dir/dist/build.noindex/灵宠岛.app"
helper="$app_dir/Contents/MacOS/lingchongdao-hook"
if [[ ! -x "$helper" ]]; then
  echo "Build dist/build.noindex/灵宠岛.app before packaging its Codex companion plugin." >&2
  exit 1
fi
/usr/bin/lipo -verify_arch arm64 "$helper"
if [[ -x /opt/homebrew/bin/python3 ]]; then
  plugin_python=/opt/homebrew/bin/python3
else
  plugin_python="$(command -v python3 || true)"
fi
if [[ -z "$plugin_python" ]]; then
  echo "Python 3 is required for offline developer validation; plugin users do not need it." >&2
  exit 1
fi
"$plugin_python" "$source_dir/verify.py"
/bin/sh -n "$source_dir/plugins/lingchongdao-codex/scripts/forward-hook.sh"

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
staging_dir="$(mktemp -d "$output_dir/.lingchongdao-package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
package_dir="$staging_dir/LingChongDaoCodexPlugin"
mkdir -p "$package_dir"
/usr/bin/ditto --norsrc --noextattr "$source_dir/.agents" "$package_dir/.agents"
/usr/bin/ditto --norsrc --noextattr "$source_dir/plugins" "$package_dir/plugins"
if [[ -n "$plugin_icon" ]]; then
  cp "$plugin_icon" "$package_dir/plugins/lingchongdao-codex/assets/icon.png"
fi
cp "$source_dir/README.md" "$package_dir/README.md"
cp "$project_dir/LICENSE" "$package_dir/LICENSE"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$package_dir/THIRD_PARTY_NOTICES.md"
mkdir -p "$package_dir/plugins/lingchongdao-codex/bin"
cp "$helper" "$package_dir/plugins/lingchongdao-codex/bin/lingchongdao-hook"
chmod 755 "$package_dir/plugins/lingchongdao-codex/bin/lingchongdao-hook"

artwork_profile=public
if [[ -n "$plugin_icon" ]]; then artwork_profile=local-only; fi
"$plugin_python" - "$package_dir" "$app_dir/Contents/Info.plist" "$artwork_profile" <<'PY_METADATA'
import hashlib, json, plistlib, sys
from pathlib import Path
root = Path(sys.argv[1])
plugin = root / 'plugins/lingchongdao-codex'
manifest = json.loads((plugin / '.codex-plugin/plugin.json').read_text())
marketplace = json.loads((root / '.agents/plugins/marketplace.json').read_text())
entry = marketplace['plugins'][0]
assert (root / entry['source']['path']).resolve() == plugin.resolve()
assert entry['name'] == manifest['name']
assert (plugin / manifest['hooks']).is_file()
with Path(sys.argv[2]).open('rb') as source:
    app = plistlib.load(source)
metadata = {
    'format': 'lingchongdao-codex-local-marketplace-v1',
    'pluginVersion': manifest['version'],
    'appVersion': app['CFBundleShortVersionString'],
    'appBundleIdentifier': app['CFBundleIdentifier'],
    'helperName': 'lingchongdao-hook',
    'applicationSupportDirectory': 'LingChongDao',
    'platform': 'mac-arm64',
    'artworkProfile': sys.argv[3],
    'helperSHA256': hashlib.sha256((plugin / 'bin/lingchongdao-hook').read_bytes()).hexdigest(),
}
(root / 'package-info.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
PY_METADATA

# --help validates that the packaged binary is runnable, without reading stdin
# or sending a session event to the user's running app.
"$package_dir/plugins/lingchongdao-codex/bin/lingchongdao-hook" --help >/dev/null
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$package_dir" "$staging_dir/LingChongDaoCodexPlugin.zip"
"$plugin_python" - "$staging_dir/LingChongDaoCodexPlugin.zip" <<'PY_ARCHIVE'
import json, stat, sys, zipfile
from pathlib import PurePosixPath
with zipfile.ZipFile(sys.argv[1]) as archive:
    names = archive.namelist()
    for name in names:
        path = PurePosixPath(name)
        assert not path.is_absolute() and '..' not in path.parts
        assert path.parts[0] == 'LingChongDaoCodexPlugin'
    assert not any(name.endswith('/bin/ai-island-hook') for name in names)
    prefix = 'LingChongDaoCodexPlugin/'
    required = ['README.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
                '.agents/plugins/marketplace.json', 'package-info.json',
                'plugins/lingchongdao-codex/LICENSE',
                'plugins/lingchongdao-codex/NOTICE.md',
                'plugins/lingchongdao-codex/.codex-plugin/plugin.json',
                'plugins/lingchongdao-codex/hooks/hooks.json',
                'plugins/lingchongdao-codex/scripts/forward-hook.sh',
                'plugins/lingchongdao-codex/bin/lingchongdao-hook']
    for path in required:
        assert prefix + path in names, path
    for path in required:
        if path.endswith('.json'):
            json.loads(archive.read(prefix + path))
    mode = archive.getinfo(prefix + required[-1]).external_attr >> 16
    assert mode & stat.S_IXUSR
PY_ARCHIVE

# Replace only the fixed build output that this script previously created.
target_dir="$output_dir/LingChongDaoCodexPlugin"
if [[ -e "$target_dir" ]]; then
  if [[ ! -f "$target_dir/package-info.json" ]] || [[ "$(/usr/bin/plutil -extract format raw -o - "$target_dir/package-info.json" 2>/dev/null || true)" != "lingchongdao-codex-local-marketplace-v1" ]]; then
    echo "Refusing to replace an unrecognized output directory: $target_dir" >&2
    exit 1
  fi
  rm -rf "$target_dir"
fi
mv "$package_dir" "$target_dir"
mv -f "$staging_dir/LingChongDaoCodexPlugin.zip" "$output_dir/LingChongDaoCodexPlugin.zip"
printf '%s\n' "$output_dir/LingChongDaoCodexPlugin.zip"
