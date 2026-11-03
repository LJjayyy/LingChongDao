#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
swift build --product LingChongDao
framework_dir="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
verification_dir="$(mktemp -d /private/tmp/lingchongdao-updates.XXXXXX)"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -swift-version 5 -F "$framework_dir" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$framework_dir" \
  Sources/LingChongDao/Updates/AppUpdateController.swift \
  Tests/AppUpdateVerification/Verification.swift -o "$verification_dir/verify"
"$verification_dir/verify"
