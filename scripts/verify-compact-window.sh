#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/lingchongdao-compact.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -swift-version 5 \
  Sources/LingChongDao/Windows/IslandMotion.swift \
  Sources/LingChongDao/Windows/IslandWindowContext.swift \
  Tests/CompactWindowVerification/Verification.swift \
  -o "$verification_dir/lingchongdao-verify-compact-window"
"$verification_dir/lingchongdao-verify-compact-window"
