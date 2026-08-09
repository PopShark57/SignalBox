#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
CONFIGURATION=${1:-debug}

cd "$PROJECT_DIR"

print "== Property lists =="
/usr/bin/plutil -lint Resources/Info.plist Config/Signalbox.entitlements

print "\n== Build (warnings are treated as defects) =="
BUILD_LOG=$(mktemp)
trap '/bin/rm -f "$BUILD_LOG"' EXIT
swift build --configuration "$CONFIGURATION" 2>&1 | /usr/bin/tee "$BUILD_LOG"
if /usr/bin/grep -q "warning:" "$BUILD_LOG"; then
    print "verify: the build emitted warnings" >&2
    exit 1
fi

print "\n== Tests =="
swift test

print "\n== Prohibited constructs =="
# Signalbox promises no networking, telemetry, privileged escalation, forced
# termination, or permanent deletion. Grep is a blunt instrument, so this is a
# tripwire for accidental reintroduction, not a security boundary.
FORBIDDEN='URLSession|NSURLConnection|CFSocket|Network\.framework|import Network|AuthorizationCreate|SMJobBless|forceTerminate|NSTask|Process\(\)|removeItem\(at: *source|unlink\(|sudo '
if /usr/bin/grep -REn "$FORBIDDEN" Sources; then
    print "verify: a prohibited construct appeared in Sources" >&2
    exit 1
fi
print "none found"

print "\n== Application bundle =="
"$SCRIPT_DIR/build-app.sh" "$CONFIGURATION"
APP_DIR="$PROJECT_DIR/Build/Signalbox.app"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# A symlink inside the bundle would be signed but could be repointed later.
if /usr/bin/find "$APP_DIR" -type l | /usr/bin/grep -q .; then
    print "verify: the application bundle contains a symbolic link" >&2
    exit 1
fi

print "\nverify: all checks passed"
