#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$#" -eq 0 ]] || { echo 'Usage: scripts/verify-all.sh' >&2; exit 2; }
cd "$project_dir"
# Run graphics/timing probes sequentially, and honor each script's own shebang.
# The real-Claude CLI probe and --live pet inspection remain opt-in.
checks=(
  verify.sh verify-runtime-identity.sh verify-codex-plugin-install.sh
  verify-application.sh verify-expired-requests.sh verify-approval-observation.sh
  verify-codex-approvals.sh verify-claude-approvals.sh verify-qoder-approvals.sh
  verify-codex-questions.sh verify-navigation.sh verify-status-summary.sh
  verify-source-attention.sh verify-attention-reveal.sh verify-pets.sh
  verify-origins.sh verify-clamshell-guard.sh verify-keep-awake.sh
  verify-compact-window.sh verify-motion.sh verify-pet-renderer.sh
  verify-boss-pet-motion.sh verify-connection-layout.sh verify-workbench-navigation.sh
)
for check in "${checks[@]}"; do
  printf '\nRunning %s\n' "$check"
  "$project_dir/scripts/$check"
done
printf '\nPASS all %s verification scripts\n' "${#checks[@]}"
