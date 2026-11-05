#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-debug}"
if [[ "$#" -gt 0 ]]; then shift; fi
if [[ "$#" -eq 1 && "$1" == "--with-local-artwork" ]]; then
  # Compatibility with the former opt-in flag; mascot artwork is now the default.
  shift
elif [[ "$#" -ne 0 ]]; then
  echo "Usage: scripts/build-app.sh [debug|release] [--with-local-artwork]" >&2
  exit 2
fi
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "Usage: scripts/build-app.sh [debug|release] [--with-local-artwork]" >&2
  exit 2
fi
if [[ "$configuration" == "release" ]]; then
  python3 - <<'PY'
import base64, os, sys
try:
    valid = len(base64.b64decode(os.environ.get('LINGCHONGDAO_SPARKLE_PUBLIC_KEY', ''), validate=True)) == 32
except ValueError:
    valid = False
if not valid:
    sys.exit('Release 构建需要有效的 LINGCHONGDAO_SPARKLE_PUBLIC_KEY（32 字节 Ed25519 公钥的 Base64）。')
PY
fi
for relative in assets/app-icon/AppIcon.icns assets/app-icon/MenuBarIcon.png \
  assets/default-pet/boss-mouse.png assets/default-pet/boss-mouse-actions.png \
  assets/default-pet/boss-mouse-performance.png assets/default-pet/boss-mouse-performance.json; do
  [[ -s "$project_dir/$relative" ]] || { echo "缺少品牌素材：$relative" >&2; exit 1; }
done
cd "$project_dir"
build_options=(-c "$configuration")
if [[ "$configuration" == "release" ]]; then
  # Map both source literals and debug records before compilation. The copied
  # binaries are stripped below as a second layer, before hashing/signing them.
  for flag in -file-prefix-map -debug-prefix-map; do
    build_options+=(-Xswiftc "$flag" -Xswiftc "$project_dir=/src/LingChongDao")
    build_options+=(-Xswiftc "$flag" -Xswiftc "$HOME=/build-user")
  done
  build_options+=(-Xswiftc -file-compilation-dir -Xswiftc /src/LingChongDao)
fi
swift build "${build_options[@]}"
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
sparkle_dir="$project_dir/.build/artifacts/sparkle/Sparkle"
sparkle_framework="$sparkle_dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$sparkle_framework" ]] || { echo '缺少 SwiftPM Sparkle framework 工件。' >&2; exit 1; }
app_dir="$project_dir/dist/build.noindex/灵宠岛.app"
# Always regenerate this managed resource tree so removed resources cannot linger.
rm -rf "$app_dir/Contents/Resources"
rm -rf "$app_dir/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
/usr/bin/ditto --norsrc --noextattr "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"
cp "$sparkle_dir/LICENSE" "$app_dir/Contents/Resources/Sparkle-LICENSE"
cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Remove only binaries from the former identity when reusing a local bundle.
rm -f "$app_dir/Contents/MacOS/AIIsland" "$app_dir/Contents/MacOS/ai-island-hook"
cp "$project_dir/assets/app-icon/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$project_dir/assets/app-icon/MenuBarIcon.png" "$app_dir/Contents/Resources/MenuBarIcon.png"
mkdir -p "$app_dir/Contents/Resources/DefaultPet"
for name in boss-mouse.png boss-mouse-actions.png boss-mouse-performance.png boss-mouse-performance.json; do
  cp "$project_dir/assets/default-pet/$name" "$app_dir/Contents/Resources/DefaultPet/$name"
done
cp "$binary_dir/LingChongDao" "$app_dir/Contents/MacOS/LingChongDao"
cp "$binary_dir/lingchongdao-hook" "$app_dir/Contents/MacOS/lingchongdao-hook"
if [[ "$configuration" == "release" ]]; then
  /usr/bin/strip -S "$app_dir/Contents/MacOS/LingChongDao" "$app_dir/Contents/MacOS/lingchongdao-hook"
  /usr/bin/codesign --force --sign - "$app_dir/Contents/MacOS/lingchongdao-hook"
fi
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>灵宠岛</string>
<key>CFBundleDisplayName</key><string>灵宠岛</string>
<key>CFBundleIdentifier</key><string>local.lingchongdao.app</string>
<key>CFBundleVersion</key><string>45</string>
<key>CFBundleShortVersionString</key><string>0.1.44</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundleExecutable</key><string>LingChongDao</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LingChongDaoArtworkProfile</key><string>public</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :LingChongDaoBuildConfiguration string $configuration" "$app_dir/Contents/Info.plist"
python3 - "$app_dir/Contents/Info.plist" "$configuration" <<'PY'
import os, plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
metadata = plistlib.loads(path.read_bytes())
metadata.update({
    'SUFeedURL': 'https://github.com/LJjayyy/LingChongDao/releases/latest/download/appcast.xml',
    'SUEnableAutomaticChecks': False,
    'SUAutomaticallyUpdate': False,
    'SUAllowsAutomaticUpdates': False,
    'SUEnableSystemProfiling': False,
    'SUVerifyUpdateBeforeExtraction': True,
})
if sys.argv[2] == 'release':
    metadata['SUPublicEDKey'] = os.environ['LINGCHONGDAO_SPARKLE_PUBLIC_KEY']
if os.environ.get('LINGCHONGDAO_UPDATE_TESTING') == '1':
    metadata['LingChongDaoUpdateTesting'] = True
path.write_bytes(plistlib.dumps(metadata, sort_keys=False))
PY
"$project_dir/scripts/build-codex-plugin.sh"
cp "$project_dir/dist/codex-plugin/LingChongDaoCodexPlugin.zip" "$app_dir/Contents/Resources/LingChongDaoCodexPlugin.zip"
/usr/bin/ditto --norsrc --noextattr "$project_dir/dist/codex-plugin/LingChongDaoCodexPlugin" "$app_dir/Contents/Resources/LingChongDaoCodexPlugin"
plugin_staging="$(mktemp -d "${TMPDIR:-/tmp}/lingchongdao-plugin-artwork.XXXXXX")"
trap 'rm -rf "$plugin_staging"' EXIT
stage_plugin() {
  local source_name="$1" resource_name="$2"
  local staged="$plugin_staging/$source_name"
  /usr/bin/ditto --norsrc --noextattr "$project_dir/integrations/$source_name" "$staged"
  /usr/bin/ditto --norsrc --noextattr "$staged" "$app_dir/Contents/Resources/$resource_name"
  /usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$staged" "$app_dir/Contents/Resources/$resource_name.zip"
}
stage_plugin dsh-plugin DshPlugin
stage_plugin zcode-plugin ZcodePlugin
stage_plugin qoder-plugin QoderPlugin
stage_plugin claude-plugin ClaudePlugin
# Sign nested executables inside-out without rewriting framework content via --deep.
framework="$app_dir/Contents/Frameworks/Sparkle.framework"
for nested in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --force --sign - --preserve-metadata=entitlements "$framework/Versions/B/$nested"
done
codesign --force --sign - "$framework"
codesign --force --sign - "$app_dir/Contents/MacOS/lingchongdao-hook"
codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
if [[ "$configuration" == "release" ]]; then
  python3 "$project_dir/scripts/verify-release-security.py" "$app_dir"
fi
echo "$app_dir"
