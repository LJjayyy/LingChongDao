#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
verification_dir="$(mktemp -d /private/tmp/lingchongdao-login.XXXXXX)"
trap 'rm -rf "$verification_dir"' EXIT
swiftc -parse-as-library -swift-version 5 \
  Sources/LingChongDao/Models/LaunchAtLoginController.swift \
  Tests/LaunchAtLoginVerification/Verification.swift -o "$verification_dir/verify"
"$verification_dir/verify"
