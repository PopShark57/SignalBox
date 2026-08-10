#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${1:-release}
APP_DIR="$PROJECT_DIR/Build/Signalbox.app"
CONTENTS_DIR="$APP_DIR/Contents"

cd "$PROJECT_DIR"
swift build --configuration "$CONFIGURATION" --product Signalbox
BIN_DIR=$(swift build --configuration "$CONFIGURATION" --show-bin-path)

/bin/rm -rf "$APP_DIR"
/bin/mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
/bin/cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
/bin/cp "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
/bin/cp "$BIN_DIR/Signalbox" "$CONTENTS_DIR/MacOS/Signalbox"

RESOURCE_BUNDLE="$BIN_DIR/Signalbox_Signalbox.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    /bin/cp -R "$RESOURCE_BUNDLE" "$CONTENTS_DIR/Resources/Signalbox_Signalbox.bundle"
fi

/usr/bin/codesign \
    --force \
    --deep \
    --sign - \
    --options runtime \
    --identifier app.signalbox.macos \
    "$APP_DIR"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"
/usr/bin/printf '%s\n' "$APP_DIR"
