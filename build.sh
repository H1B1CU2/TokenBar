#!/usr/bin/env bash
set -euo pipefail

# TokenBar build wrapper.
#
#   ./build.sh          compile only
#   ./build.sh --run    compile, then quit any running copy and relaunch
#
# Unlike MSG's build.sh this does not drive swiftc directly — TokenBar has a
# real Xcode target, so the script only pins the toolchain and resolves the
# product path, the two things that are easy to get wrong by hand.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCHEME="TokenBar"
CONFIG="${CONFIG:-Release}"

# The source uses macOS 27 APIs — NSStatusItemExpandedInterfaceDelegate and
# NSGlassEffectView.effectIsInteractive — which the 26.x SDK in the release
# Xcode does not declare, so a build there fails with five "cannot find type"
# errors. Pin the beta, and don't fall back silently: a stale-SDK failure is
# far more confusing than a missing-Xcode message.
XCODE="${XCODE_APP:-/Applications/Xcode-beta.app}"
if [[ ! -d "$XCODE" ]]; then
    echo "❌  $XCODE not found — TokenBar needs the macOS 27 SDK."
    echo "    Point XCODE_APP at an Xcode that ships it."
    exit 1
fi
export DEVELOPER_DIR="$XCODE/Contents/Developer"

echo "▸ Building $SCHEME ($CONFIG) with $(basename "$XCODE")..."
xcodebuild -project "$SCRIPT_DIR/$SCHEME.xcodeproj" \
    -scheme "$SCHEME" -configuration "$CONFIG" build | \
    grep -E "error:|warning:|BUILD" || true

# xcodebuild writes into a DerivedData directory whose name carries a hash, so
# ask it where the product actually landed rather than guessing — `open` on a
# guessed path silently falls through to whatever LaunchServices has indexed
# under the same bundle id, which is how you end up testing a stale build.
BUILD_DIR="$(xcodebuild -project "$SCRIPT_DIR/$SCHEME.xcodeproj" \
    -scheme "$SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $3}')"
APP="$BUILD_DIR/$SCHEME.app"

if [[ ! -d "$APP" ]]; then
    echo "❌  Build produced no app at $APP"
    exit 1
fi

echo ""
echo "✅  Built: $APP"

if [[ "${1:-}" == "--run" ]]; then
    echo "▸ Relaunching..."
    pkill -x "$SCHEME" 2>/dev/null || true
    sleep 1
    # -a with the full path, so LaunchServices cannot substitute another copy.
    open -a "$APP"
else
    echo ""
    echo "To run:  open -a \"$APP\""
fi
