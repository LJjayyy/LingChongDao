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
for relative in assets/app-icon/AppIcon.icns assets/app-icon/MenuBarIcon.png \
  assets/default-pet/boss-mouse.png assets/default-pet/boss-mouse-actions.png \
  assets/default-pet/boss-mouse-performance.png assets/default-pet/boss-mouse-performance.json; do
  [[ -s "$project_dir/$relative" ]] || { echo "缺少品牌素材：$relative" >&2; exit 1; }
done
cd "$project_dir"
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$project_dir/dist/build.noindex/灵宠岛.app"
# Always regenerate this managed resource tree so removed resources cannot linger.
rm -rf "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
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
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>灵宠岛</string>
<key>CFBundleDisplayName</key><string>灵宠岛</string>
<key>CFBundleIdentifier</key><string>local.lingchongdao.app</string>
<key>CFBundleVersion</key><string>41</string>
<key>CFBundleShortVersionString</key><string>0.1.40</string>
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
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
