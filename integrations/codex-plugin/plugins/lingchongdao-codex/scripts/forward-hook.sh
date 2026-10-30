#!/bin/sh
# Use the helper shipped with this installed plugin, never a developer's path.
# No process launch, config reads/edits, trust changes, or automatic decisions.
set -u
fallback() { printf '{}\n'; exit 0; }

case "${HOME:-}" in /*) ;; *) fallback ;; esac
case "${PLUGIN_ROOT:-}" in /*) ;; *) fallback ;; esac
case "${1:-}" in
    '') wait_seconds=2 ;;
    --approval) wait_seconds=45 ;;
    *) fallback ;;
esac
[ "$#" -le 1 ] || fallback

helper="$PLUGIN_ROOT/bin/lingchongdao-hook"
socket="$HOME/Library/Application Support/LingChongDao/run/bridge.sock"
[ -x "$helper" ] || fallback

# Compatibility only: an older, already-running client may still expose the
# former socket. Prefer the current socket; never retry an existing endpoint or
# borrow a global helper. A malformed current path must not select an old client.
if [ ! -e "$socket" ] && [ ! -L "$socket" ]; then
    legacy_socket="$HOME/Library/Application Support/AIIsland/run/bridge.sock"
    if [ -S "$legacy_socket" ]; then socket=$legacy_socket; fi
fi
[ -S "$socket" ] || fallback

# Native helper validates events, expiry and supported permission output.
# Missing/disconnected bridge and helper failures return no decision.
# Capture output so a failing helper cannot leak a partial approval response.
if response=$("$helper" --provider codex --socket "$socket" --timeout "$wait_seconds"); then
    printf '%s\n' "$response"
else
    fallback
fi
