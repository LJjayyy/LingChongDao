#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/lingchongdao-boss-pet.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -swift-version 5 -module-cache-path "$verification_dir/module-cache" \
  "$project_dir/Sources/LingChongDao/Pets/BossPetMotion.swift" \
  "$project_dir/Tests/BossPetMotionVerification.swift" \
  -o "$verification_dir/lingchongdao-verify-boss-pet-motion"
"$verification_dir/lingchongdao-verify-boss-pet-motion"
