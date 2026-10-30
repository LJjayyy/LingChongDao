#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
if [[ "${1:-}" != "--no-build" ]]; then swift build --product LingChongDao; fi
binary_dir="$(swift build --show-bin-path)"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/lingchongdao-approval-observation.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
if [[ -f "$binary_dir/IslandCore.o" ]]; then
  core_link=("$binary_dir/IslandCore.o")
else
  core_link=("$binary_dir"/IslandCore.build/*.o)
fi
swiftc -parse-as-library -swift-version 5 -I "$binary_dir" -I "$binary_dir/Modules" \
  Sources/LingChongDao/Models/AppSettings.swift Sources/LingChongDao/Models/AppModel.swift \
  Tests/ApprovalObservationVerification/Verification.swift \
  "${core_link[@]}" -o "$verification_dir/verify-approval-observation"
swiftc -parse-as-library -swift-version 5 Sources/IslandCore/*.swift \
  Tests/PermissionObservationCoreVerification/Verification.swift \
  -o "$verification_dir/verify-permission-observation-core"
python3 - "$verification_dir/verify-permission-observation-core" "$verification_dir/verify-approval-observation" <<'PYTIMEOUT'
import subprocess,sys
try:
    for executable in sys.argv[1:]:
        result = subprocess.run([executable], timeout=20)
        if result.returncode:
            raise SystemExit(result.returncode)
except subprocess.TimeoutExpired:
    print("FAIL: approval observation verification exceeded 20 seconds", file=sys.stderr)
    raise SystemExit(1)
PYTIMEOUT
