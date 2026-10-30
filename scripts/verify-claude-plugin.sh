#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$#" != 1 ]]; then
  echo 'Usage: scripts/verify-claude-plugin.sh /absolute/path/to/claude' >&2
  exit 2
fi
verify_dir=$(mktemp -d /private/tmp/lcd-claude-verify.XXXXXX)
trap 'rm -rf "$verify_dir"' EXIT
swiftc -module-cache-path "$verify_dir/cache" -parse-as-library -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift -o "$verify_dir/libIslandCore.dylib" -emit-module-path "$verify_dir/IslandCore.swiftmodule"
swiftc -module-cache-path "$verify_dir/cache" -parse-as-library -emit-library -emit-module -module-name IslandConnections -I "$verify_dir" -L "$verify_dir" -lIslandCore Sources/LingChongDao/Connections/*.swift -o "$verify_dir/libIslandConnections.dylib" -emit-module-path "$verify_dir/IslandConnections.swiftmodule"
swiftc -module-cache-path "$verify_dir/cache" -I "$verify_dir" -L "$verify_dir" -lIslandCore Sources/IslandHook/main.swift -o "$verify_dir/lingchongdao-hook"
swiftc -module-cache-path "$verify_dir/cache" -parse-as-library -I "$verify_dir" -L "$verify_dir" -lIslandCore -lIslandConnections Tests/ClaudeVerification/Verification.swift -o "$verify_dir/verify"
DYLD_LIBRARY_PATH="$verify_dir" "$verify_dir/verify" "$PWD/integrations/claude-plugin" "$verify_dir/lingchongdao-hook" "$1"
