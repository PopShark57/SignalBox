#!/bin/zsh

# Regenerates Resources/AppIcon.icns from Design/GenerateAppIcon.swift. The
# icon is committed, so this only needs running when the design changes.

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
WORK_DIR=$(mktemp -d)
trap '/bin/rm -rf "$WORK_DIR"' EXIT

cd "$PROJECT_DIR"
swift Design/GenerateAppIcon.swift "$WORK_DIR" > /dev/null
/usr/bin/iconutil --convert icns "$WORK_DIR/Signalbox.iconset" --output "$PROJECT_DIR/Resources/AppIcon.icns"
/bin/cp "$WORK_DIR/AppIcon-preview.png" "$PROJECT_DIR/Design/AppIcon-preview.png"
/usr/bin/printf '%s\n' "$PROJECT_DIR/Resources/AppIcon.icns"
