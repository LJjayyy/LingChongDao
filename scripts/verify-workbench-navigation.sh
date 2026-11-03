#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build --product LingChongDao
binary_dir="$(swift build --show-bin-path)"
sparkle_dir="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
module_links=()
for module in IslandCore IslandConnections IslandPets; do
  if [[ -f "$binary_dir/$module.o" ]]; then
    module_links+=("$binary_dir/$module.o")
  elif [[ -f "$binary_dir/lib$module.a" ]]; then
    module_links+=("$binary_dir/lib$module.a")
  else
    module_links+=("$binary_dir/$module.build/"*.o)
  fi
done
preview_dir="$(mktemp -d /private/tmp/lingchongdao-navigation.XXXXXX)"
trap 'rm -rf "$preview_dir"' EXIT
sources=()
while IFS= read -r path; do sources+=("$path"); done < <(find Sources/LingChongDao -name '*.swift' ! -name App.swift ! -path '*/Connections/*' | sort)
swiftc -parse-as-library -swift-version 5 -I "$binary_dir" -I "$binary_dir/Modules" \
  -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker "$sparkle_dir" \
  "${sources[@]}" Tests/WorkbenchNavigationVerification/Verification.swift \
  "${module_links[@]}" \
  -lsqlite3 -framework IOKit -o "$preview_dir/verify"
for run in 1 2 3; do "$preview_dir/verify"; done
