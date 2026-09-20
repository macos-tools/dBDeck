#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Tests isolate their state in a UserDefaults suite named for a fresh UUID.
# They empty the suite as they finish, but the preferences daemon writes
# lazily and flushes its cached copy back afterwards, so a file per test is
# left in the user's own preferences folder on every run. Deleting from
# inside the tests is a race they cannot win, and a run's own files are
# still being written as this script exits, so what this sweep collects is
# the previous run's. That holds the footprint at one run's worth instead of
# letting it grow without bound, which is what it did before.
cleanup_test_defaults() {
  local file domain
  # The daemon flushes shortly after the test process exits, so give it a
  # moment; sweeping before that just deletes files it is about to rewrite.
  sleep 1
  for file in "$HOME"/Library/Preferences/dBDeck*Tests.*.plist; do
    [ -e "$file" ] || continue
    domain="$(basename "$file" .plist)"
    case "$domain" in
      # Strictly the generated shape, so no real domain can match.
      dBDeck*Tests.????????-????-????-????-????????????)
        defaults delete -- "$domain" 2>/dev/null || true
        rm -f -- "$file"
        ;;
    esac
  done
}
trap cleanup_test_defaults EXIT
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain.sh"
VERIFY_DIR="$ROOT_DIR/.build/verification"
DISCOVERY_VERIFY_BINARY="$VERIFY_DIR/verify-audio-discovery"
FIXTURE_NAME="dBDeckAudioFixture"
FIXTURE_BUNDLE_ID="com.dbdeck.tests.audio-fixture"
FIXTURE_BUNDLE="$VERIFY_DIR/$FIXTURE_NAME.app"
FIXTURE_BINARY="$FIXTURE_BUNDLE/Contents/MacOS/$FIXTURE_NAME"

cd "$ROOT_DIR"
xcrun swift test \
  --disable-sandbox \
  --enable-swift-testing \
  --disable-xctest

mkdir -p "$VERIFY_DIR/module-cache"
swiftc \
  -swift-version 5 \
  -module-cache-path "$VERIFY_DIR/module-cache" \
  -framework AppKit \
  -framework CoreAudio \
  "$ROOT_DIR/Sources/dBDeck/Models/ApplicationIdentity.swift" \
  "$ROOT_DIR/Sources/dBDeck/Models/AudioApp.swift" \
  "$ROOT_DIR/Sources/dBDeck/Support/CoreAudioSupport.swift" \
  "$ROOT_DIR/Sources/dBDeck/Support/ApplicationBundleResolver.swift" \
  "$ROOT_DIR/Sources/dBDeck/Support/ApplicationDisplayNameResolver.swift" \
  "$ROOT_DIR/Sources/dBDeck/Support/HostApplicationIdentity.swift" \
  "$ROOT_DIR/Sources/dBDeck/Services/ApplicationIdentityResolver.swift" \
  "$ROOT_DIR/Sources/dBDeck/Services/AudioProcessDiscovery.swift" \
  "$ROOT_DIR/Tests/Integration/AudioDiscoveryVerifier.swift" \
  -o "$DISCOVERY_VERIFY_BINARY"

rm -rf "$FIXTURE_BUNDLE"
mkdir -p "$(dirname "$FIXTURE_BINARY")"
swiftc \
  -swift-version 5 \
  -module-cache-path "$VERIFY_DIR/module-cache" \
  -framework AppKit \
  "$ROOT_DIR/Tests/Fixtures/AudioFixtureApp.swift" \
  -o "$FIXTURE_BINARY"

cat >"$FIXTURE_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>dBDeck Audio Fixture</string>
  <key>CFBundleExecutable</key>
  <string>$FIXTURE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$FIXTURE_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>dBDeck Audio Fixture</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$FIXTURE_BUNDLE" >/dev/null
"$FIXTURE_BINARY" /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &
FIXTURE_PID=$!
trap 'kill "$FIXTURE_PID" >/dev/null 2>&1 || true' EXIT
sleep 0.3
"$DISCOVERY_VERIFY_BINARY" "$FIXTURE_BUNDLE_ID"
