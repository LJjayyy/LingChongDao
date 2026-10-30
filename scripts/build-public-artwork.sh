#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$#" -gt 1 ]]; then
  echo 'Usage: scripts/build-public-artwork.sh [OUTPUT_DIRECTORY]' >&2
  exit 2
fi
output_dir="${1:-$project_dir/dist/public-artwork}"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/lingchongdao-public-artwork.XXXXXX")"
trap 'rm -rf "$temporary_dir"' EXIT
swiftc -O -framework AppKit "$project_dir/scripts/PublicArtwork.swift" -o "$temporary_dir/PublicArtwork"
"$temporary_dir/PublicArtwork" "$output_dir"
iconutil --convert icns --output "$output_dir/AppIcon.icns" "$output_dir/AppIcon.iconset"
echo "$output_dir"
