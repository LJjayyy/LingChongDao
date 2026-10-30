#!/bin/bash
# Install the verified local build at one stable macOS application path.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--no-build" ) ]]; then
  echo "Usage: scripts/install-local.sh [--no-build]" >&2
  exit 2
fi
if /usr/bin/pgrep -x 'LingChongDao|AIIsland' >/dev/null; then
  echo "请先从菜单栏退出灵宠岛，再安装更新。" >&2
  exit 1
fi
if [[ "$#" -eq 0 ]]; then "$project_dir/scripts/build-app.sh" release; fi
source_app="$project_dir/dist/build.noindex/灵宠岛.app"
target_app="/Applications/灵宠岛.app"
plist_tool=/usr/libexec/PlistBuddy
registry=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[[ -d "$source_app" && ! -L "$source_app" ]] || { echo "请先构建完整应用。" >&2; exit 1; }
[[ "$($plist_tool -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == 'local.lingchongdao.app' ]]
[[ "$($plist_tool -c 'Print :CFBundleIconFile' "$source_app/Contents/Info.plist")" == 'AppIcon.icns' ]]
[[ -s "$source_app/Contents/Resources/AppIcon.icns" ]]
[[ -s "$source_app/Contents/Resources/MenuBarIcon.png" ]]
/usr/bin/codesign --verify --deep --strict "$source_app"
if [[ -e "$target_app" || -L "$target_app" ]]; then
  [[ -d "$target_app" && ! -L "$target_app" ]] || { echo "目标不是可替换的应用目录：$target_app" >&2; exit 1; }
  target_id="$($plist_tool -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")"
  [[ "$target_id" == 'local.lingchongdao.app' || "$target_id" == 'local.ai-island.app' ]] || { echo "目标不是本应用，已保留：$target_app" >&2; exit 1; }
fi
stage_dir="$(mktemp -d /Applications/.lingchongdao-install.XXXXXX)"
previous_app=''
installed=0
cleanup() {
  if [[ "$installed" == 0 && -n "$previous_app" && ! -e "$target_app" ]]; then mv "$previous_app" "$target_app"; fi
  rm -rf "$stage_dir"
}
trap cleanup EXIT
/usr/bin/ditto --norsrc --noextattr "$source_app" "$stage_dir/灵宠岛.app"
/usr/bin/codesign --verify --deep --strict "$stage_dir/灵宠岛.app"
# The app may have been launched while the build or copy was in progress.
if /usr/bin/pgrep -x 'LingChongDao|AIIsland' >/dev/null; then
  echo "安装期间检测到灵宠岛已启动，请退出后重试。" >&2
  exit 1
fi
if [[ -e "$target_app" ]]; then
  mkdir -p "$project_dir/dist/rollback.noindex"
  rollback_dir="$(mktemp -d "$project_dir/dist/rollback.noindex/install.XXXXXX")"
  previous_app="$rollback_dir/灵宠岛.app"
  mv "$target_app" "$previous_app"
fi
mv "$stage_dir/灵宠岛.app" "$target_app"
installed=1
# Refresh this application only; never reset the system-wide registry.
"$registry" -f "$target_app"
printf '已安装：%s\n' "$target_app"
