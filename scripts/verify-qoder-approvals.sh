#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
binary_dir="$(swift build --show-bin-path)"
verification_dir="$(mktemp -d /private/tmp/lcd-qoder-approvals.XXXXXX)"
trap 'rm -rf "$verification_dir"' EXIT
if [[ -f "$binary_dir/IslandCore.o" ]]; then
  core_link=("$binary_dir/IslandCore.o")
elif [[ -f "$binary_dir/libIslandCore.a" ]]; then
  core_link=("$binary_dir/libIslandCore.a")
else
  core_link=("$binary_dir"/IslandCore.build/*.o)
fi
swiftc -parse-as-library -swift-version 5 -I "$binary_dir" -I "$binary_dir/Modules" \
  Sources/LingChongDao/Models/AppSettings.swift Sources/LingChongDao/Models/AppModel.swift \
  Tests/QoderApprovalVerification/Verification.swift "${core_link[@]}" -o "$verification_dir/verify"
"$verification_dir/verify" "$binary_dir/lingchongdao-hook"
