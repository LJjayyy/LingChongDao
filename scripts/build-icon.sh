#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ASSET="$PROJECT_DIR/assets/default-pet/boss-mouse.png"
OUTPUT_DIR="$PROJECT_DIR/assets/app-icon"
ICONSET="$OUTPUT_DIR/AppIcon.iconset"
PREVIEW="$OUTPUT_DIR/AppIcon-preview.png"
ICON="$OUTPUT_DIR/AppIcon.icns"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lingchongdao-icon.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

for tool in swiftc iconutil sips; do
    command -v "$tool" >/dev/null 2>&1 || { echo "build-icon: required tool not found: $tool" >&2; exit 1; }
done
[ -f "$ASSET" ] || { echo "build-icon: mascot asset not found: $ASSET" >&2; exit 1; }

mkdir -p "$OUTPUT_DIR"
swiftc -O -framework AppKit -framework ImageIO \
    "$SCRIPT_DIR/AppIcon.swift" \
    -o "$TEMP_DIR/AppIcon"
"$TEMP_DIR/AppIcon" "$ASSET" "$PREVIEW" "$ICONSET"
iconutil --convert icns --output "$ICON" "$ICONSET"
sips -g pixelWidth -g pixelHeight "$PREVIEW" >/dev/null
sips -g format "$ICON" | grep -q 'icns' || { echo "build-icon: generated icon is not readable as ICNS" >&2; exit 1; }
echo "Built: $ICON"
echo "Preview: $PREVIEW"
echo "Iconset: $ICONSET (10 standard sizes)"
