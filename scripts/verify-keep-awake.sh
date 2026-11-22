#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp/}lingchongdao-keep-awake.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -swift-version 5 -framework IOKit \
  -module-cache-path "$verification_dir/module-cache" \
  Sources/LingChongDao/Models/KeepAwakeController.swift \
  Sources/LingChongDao/Models/ClamshellSleepGuard.swift \
  Sources/LingChongDao/Models/ClamshellGuardCommand.swift \
  Sources/LingChongDao/Models/KeepAwakeHelperInstallation.swift \
  Sources/LingChongDao/Models/KeepAwakeSessionBroker.swift \
  Sources/LingChongDao/Models/KeepAwakeAuthorization.swift \
  Tests/KeepAwakeVerification/Verification.swift \
  -o "$verification_dir/lingchongdao-verify-keep-awake"
"$verification_dir/lingchongdao-verify-keep-awake"
