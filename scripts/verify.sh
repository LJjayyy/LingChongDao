#!/bin/sh
set -eu

# Uses a standalone executable so Command Line Tools installations do not need XCTest.
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec swift run --package-path "$PROJECT_ROOT" lingchongdao-verify "$@"
