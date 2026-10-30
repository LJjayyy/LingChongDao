#!/bin/sh
set -eu
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec swift run --package-path "$PROJECT_ROOT" lingchongdao-origin-verify "$@"
