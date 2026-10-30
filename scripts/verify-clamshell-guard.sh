#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp/}lingchongdao-clamshell.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -swift-version 5 \
  Sources/LingChongDao/Models/ClamshellSleepGuard.swift \
  Tests/ClamshellGuardVerification/Verification.swift \
  -o "$verification_dir/lingchongdao-verify-clamshell-guard"
"$verification_dir/lingchongdao-verify-clamshell-guard"
