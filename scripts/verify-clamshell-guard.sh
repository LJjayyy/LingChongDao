#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp/}lingchongdao-clamshell.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -swift-version 5 \
  -module-cache-path "$verification_dir/module-cache" \
  Sources/LingChongDao/Models/ClamshellSleepGuard.swift \
  Sources/LingChongDao/Models/ClamshellGuardCommand.swift \
  Sources/LingChongDao/Models/KeepAwakeHelperInstallation.swift \
  Sources/LingChongDao/Models/KeepAwakeSessionBroker.swift \
  Sources/LingChongDao/Models/KeepAwakeAuthorization.swift \
  Sources/KeepAwakeHelper/KeepAwakeHelper.swift \
  Tests/ClamshellGuardVerification/BrokerClientVerification.swift \
  Tests/ClamshellGuardVerification/Verification.swift \
  -o "$verification_dir/lingchongdao-verify-clamshell-guard"
"$verification_dir/lingchongdao-verify-clamshell-guard"
