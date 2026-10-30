#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--no-build" ) ]]; then
  echo 'Usage: scripts/package-dmg.sh [--no-build]' >&2
  exit 2
fi
if [[ "$#" -eq 0 ]]; then "$project_dir/scripts/build-app.sh" release; fi

app_dir="$project_dir/dist/build.noindex/灵宠岛.app"
plist="$app_dir/Contents/Info.plist"
[[ -d "$app_dir" && ! -L "$app_dir" ]] || { echo '请先构建完整应用。' >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == 'local.lingchongdao.app' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LingChongDaoArtworkProfile' "$plist")" == 'public' ]]
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo '应用版本必须为 x.y.z。' >&2; exit 1; }
/usr/bin/lipo "$app_dir/Contents/MacOS/LingChongDao" -verify_arch arm64
/usr/bin/lipo "$app_dir/Contents/MacOS/lingchongdao-hook" -verify_arch arm64
/usr/bin/codesign --verify --deep --strict "$app_dir"

output_dir="$project_dir/dist/release"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.dmg-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
payload="$staging_dir/payload"
mkdir "$payload"
/usr/bin/ditto --norsrc --noextattr --noacl --noqtn "$app_dir" "$payload/灵宠岛.app"
/usr/bin/codesign --verify --deep --strict "$payload/灵宠岛.app"
ln -s /Applications "$payload/Applications"
cp "$project_dir/docs/DMG-安装说明.txt" "$payload/安装说明.txt"
cp "$project_dir/LICENSE" "$payload/LICENSE.txt"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$payload/THIRD_PARTY_NOTICES.md"
cp "$project_dir/PRIVACY.md" "$payload/PRIVACY.md"
cp "$project_dir/SECURITY.md" "$payload/SECURITY.md"
mkdir "$payload/docs"
cp "$project_dir/docs/卸载与数据清理.md" "$payload/docs/卸载与数据清理.md"

dmg_name="LingChongDao-$version-macOS-arm64.dmg"
/usr/bin/hdiutil create -volname "灵宠岛 $version" -srcfolder "$payload" \
  -fs HFS+ -format UDZO -nospotlight "$staging_dir/$dmg_name"
/usr/bin/hdiutil verify "$staging_dir/$dmg_name"
(
  cd "$staging_dir"
  /usr/bin/shasum -a 256 "$dmg_name" > SHA256SUMS.txt
)
mv -f "$staging_dir/$dmg_name" "$output_dir/$dmg_name"
mv -f "$staging_dir/SHA256SUMS.txt" "$output_dir/SHA256SUMS.txt"
printf '已生成安装映像：%s\n校验值：%s\n' "$output_dir/$dmg_name" "$output_dir/SHA256SUMS.txt"
