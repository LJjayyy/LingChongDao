#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/lingchongdao-workbuddy.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
cd "$project_dir"
# Independent of SwiftPM/XCTest, and does not contend with an app build.
swiftc -parse-as-library -swift-version 5 -module-cache-path "$build_dir/module-cache" \
  -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift \
  -emit-module-path "$build_dir/IslandCore.swiftmodule" -o "$build_dir/libIslandCore.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$build_dir/module-cache" \
  -I "$build_dir" -L "$build_dir" -lIslandCore -Xlinker -rpath -Xlinker "$build_dir" \
  Tests/WorkBuddyVerification/Verification.swift -o "$build_dir/workbuddy-verification"
"$build_dir/workbuddy-verification"
