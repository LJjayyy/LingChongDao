#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
binary_dir="$(swift build --show-bin-path)"
verification_dir="$(mktemp -d /private/tmp/lcd-codex-questions.XXXXXX)"
trap 'rm -rf "$verification_dir"' EXIT
if [[ -f "$binary_dir/IslandCore.o" ]]; then
  core_link=("$binary_dir/IslandCore.o")
elif [[ -f "$binary_dir/libIslandCore.a" ]]; then
  core_link=("$binary_dir/libIslandCore.a")
else
  core_link=("$binary_dir"/IslandCore.build/*.o)
fi
swiftc -parse-as-library -swift-version 5 -I "$binary_dir" -I "$binary_dir/Modules" \
  Tests/CodexQuestionVerification/Verification.swift "${core_link[@]}" -o "$verification_dir/verify"
"$verification_dir/verify"
