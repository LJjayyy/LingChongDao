#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" != "--no-build" ]]; then swift build --product LingChongDao; fi
binary_dir="$(swift build --show-bin-path)"
if [[ -f "$binary_dir/IslandCore.o" ]]; then
  core_link=("$binary_dir/IslandCore.o")
elif [[ -f "$binary_dir/libIslandCore.a" ]]; then
  core_link=("$binary_dir/libIslandCore.a")
else
  core_link=("$binary_dir"/IslandCore.build/*.o)
fi
swiftc -parse-as-library -swift-version 5 -I "$binary_dir" -I "$binary_dir/Modules" \
  Sources/LingChongDao/Models/AppSettings.swift Sources/LingChongDao/Models/AppModel.swift \
  Tests/VerificationSupport/CodexReviewFixture.swift \
  Tests/ExpiredRequestVerification/ExpiredRequestVerification.swift \
  "${core_link[@]}" -o "$binary_dir/lingchongdao-verify-expired-requests"
"$binary_dir/lingchongdao-verify-expired-requests"
