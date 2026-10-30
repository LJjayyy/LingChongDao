#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
verification_dir="$(mktemp -d "${TMPDIR:-/tmp}/lingchongdao-motion.XXXXXX")"
trap 'rm -rf "$verification_dir"' EXIT
# Build the actual view's dependency. The verification executable is compiled
# separately; it never starts the production bridge or reads provider pets.
swift build --product LingChongDao
binary_dir="$(swift build --show-bin-path)"
if [[ -f "$binary_dir/IslandCore.o" ]]; then
  core_link=("$binary_dir/IslandCore.o")
else
  shopt -s nullglob
  core_link=("$binary_dir"/IslandCore.build/*.o)
  if [[ ${#core_link[@]} -eq 0 ]]; then
    echo "FAIL current IslandCore object files were not found" >&2
    exit 1
  fi
fi
python3 - "$project_dir/Sources/LingChongDao/Views/DesignTokens.swift" "$verification_dir/DesignTokens.swift" <<'PY'
import sys
with open(sys.argv[1], encoding='utf-8') as source:
    text = source.read()
needle = '    func path(in rect: CGRect) -> Path {\n'
assert text.count(needle) == 1, 'Motion observer insertion point must identify only IslandShell.path'
replacement = needle + '        MotionVerificationSamples.onPath?(rect.width, rect.height, expansion)\n'
instrumented = text.replace(needle, replacement, 1)
assert instrumented.replace(replacement, needle, 1) == text, 'Only the passive path observer may differ'
with open(sys.argv[2], 'w', encoding='utf-8') as target:
    target.write(instrumented)
PY
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -module-cache-path "$verification_dir/module-cache" \
  -I "$binary_dir" -I "$binary_dir/Modules" \
  "$verification_dir/DesignTokens.swift" \
  Sources/LingChongDao/Views/SwipeDismissRow.swift \
  Sources/LingChongDao/Views/IslandView.swift \
  Sources/LingChongDao/Views/IdleBossEncounterView.swift \
  Sources/LingChongDao/Views/BossWorkbenchStyle.swift \
  Sources/LingChongDao/Windows/IslandMotion.swift \
  Sources/LingChongDao/Windows/IslandWindowContext.swift \
  Sources/LingChongDao/Windows/IslandPanel.swift \
  Sources/LingChongDao/Windows/IslandWindowCoordinator.swift \
  Sources/LingChongDao/Models/AppSettings.swift Sources/LingChongDao/Models/AppModel.swift \
  Sources/LingChongDao/Models/KeepAwakeController.swift \
  Sources/LingChongDao/Models/ClamshellSleepGuard.swift \
  Tests/MotionVerification/Verification.swift \
  "${core_link[@]}" -o "$verification_dir/lingchongdao-verify-motion"
"$verification_dir/lingchongdao-verify-motion" "$@"
