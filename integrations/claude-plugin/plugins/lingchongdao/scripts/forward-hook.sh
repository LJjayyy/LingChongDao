#!/bin/sh
# PermissionRequest waits on one correlated helper connection. Other hooks only
# observe. Missing helper / bridge failures return empty success to Claude.
helper="${HOME}/Library/Application Support/LingChongDao/bin/lingchongdao-hook"
socket="${HOME}/Library/Application Support/LingChongDao/run/bridge.sock"
if [ -x "$helper" ]; then
    exec "$helper" --provider claude --socket "$socket" "$@"
fi
printf '{}\n'
exit 0
