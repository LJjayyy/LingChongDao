#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build --product LingChongDao
binary_dir="$(swift build --show-bin-path)"
preview_dir="$(mktemp -d /private/tmp/lingchongdao-layout.XXXXXX)"
trap 'rm -rf "$preview_dir"' EXIT
sources=()
while IFS= read -r path; do sources+=("$path"); done < <(find Sources/LingChongDao -name '*.swift' ! -name App.swift ! -path '*/Connections/*' | sort)
swiftc -parse-as-library -swift-version 5 -I "$binary_dir" -I "$binary_dir/Modules" \
  "${sources[@]}" Tests/ConnectionLayoutVerification/Verification.swift \
  "$binary_dir/IslandCore.o" "$binary_dir/IslandConnections.o" "$binary_dir/IslandPets.o" \
  -lsqlite3 -framework IOKit -o "$preview_dir/verify"
for run in 1 2 3; do "$preview_dir/verify"; done
