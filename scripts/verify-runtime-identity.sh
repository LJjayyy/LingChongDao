#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d /private/tmp/lingchongdao-identity-verification.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
source_dir="$project_dir/Sources/LingChongDao"
swiftc -swift-version 5 -emit-module -emit-library -module-name IslandCore \
  "$project_dir"/Sources/IslandCore/*.swift \
  -o "$build_dir/libIslandCore.dylib" -emit-module-path "$build_dir/IslandCore.swiftmodule"
swiftc -swift-version 5 -parse-as-library -I "$build_dir" -L "$build_dir" -lIslandCore \
  -Xlinker -rpath -Xlinker "$build_dir" \
  "$source_dir"/Connections/*.swift "$project_dir/Tests/RuntimeIdentityVerification/main.swift" \
  -o "$build_dir/verify"
"$build_dir/verify"
