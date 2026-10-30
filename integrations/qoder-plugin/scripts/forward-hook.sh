#!/bin/sh
# 灵宠岛 · Qoder hook forwarder.
#
# The hook command is static inside the plugin package, so the helper and socket
# are resolved from the user's home directory at run time. A missing helper or a
# stopped app must never block Qoder: print an empty object and succeed.

home=${HOME:-}
helper="$home/Library/Application Support/LingChongDao/bin/lingchongdao-hook"
socket="$home/Library/Application Support/LingChongDao/run/bridge.sock"

if [ -x "$helper" ]; then
    exec "$helper" --provider qoder --socket "$socket" "$@"
fi

printf '{}\n'
exit 0
