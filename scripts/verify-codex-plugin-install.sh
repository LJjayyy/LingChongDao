#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERIFY_DIR=$(mktemp -d /private/tmp/lcd-plugin-verify.XXXXXX)
trap 'rm -rf "$VERIFY_DIR"' EXIT
swiftc -module-cache-path "$VERIFY_DIR/cache" -parse-as-library -emit-library -emit-module -module-name IslandCore Sources/IslandCore/*.swift -o "$VERIFY_DIR/libIslandCore.dylib" -emit-module-path "$VERIFY_DIR/IslandCore.swiftmodule"
swiftc -module-cache-path "$VERIFY_DIR/cache" -parse-as-library -emit-library -emit-module -module-name IslandConnections -I "$VERIFY_DIR" -L "$VERIFY_DIR" -lIslandCore Sources/LingChongDao/Connections/*.swift -o "$VERIFY_DIR/libIslandConnections.dylib" -emit-module-path "$VERIFY_DIR/IslandConnections.swiftmodule"
swiftc -module-cache-path "$VERIFY_DIR/cache" -parse-as-library -I "$VERIFY_DIR" -L "$VERIFY_DIR" -lIslandCore -lIslandConnections Tests/CodexPluginVerification/main.swift -o "$VERIFY_DIR/verify"
DYLD_LIBRARY_PATH="$VERIFY_DIR" "$VERIFY_DIR/verify" "$PWD/dist/codex-plugin/LingChongDaoCodexPlugin"
