#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp/}lingchongdao-keep-awake.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -swift-version 5 -framework IOKit \
  Sources/LingChongDao/Models/KeepAwakeController.swift \
  Sources/LingChongDao/Models/ClamshellSleepGuard.swift \
  Tests/KeepAwakeVerification/Verification.swift \
  -o "$verification_dir/lingchongdao-verify-keep-awake"
"$verification_dir/lingchongdao-verify-keep-awake"
