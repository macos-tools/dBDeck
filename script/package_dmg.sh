#!/usr/bin/env bash
set -euo pipefail

APP_NAME="dBDeck"
RELEASE_VERSION="${1:-0.2.0}"

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "usage: $0 [numeric-version, for example 0.1.0]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$ROOT_DIR/.build/verification/release/$APP_NAME.app"
DMG_NAME="$APP_NAME-$RELEASE_VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"

DBDECK_APP_VERSION="$RELEASE_VERSION" \
  "$ROOT_DIR/script/build_and_run.sh" --release-stage

/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
/usr/bin/lipo "$APP_BUNDLE/Contents/MacOS/$APP_NAME" -verify_arch arm64 x86_64
/usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist"

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.dBDeck-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

PAYLOAD_DIR="$STAGING_DIR/payload"
mkdir -p "$PAYLOAD_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$PAYLOAD_DIR/$APP_NAME.app"
ln -s /Applications "$PAYLOAD_DIR/Applications"

/usr/bin/hdiutil create \
  -ov \
  -format UDZO \
  -volname "$APP_NAME $RELEASE_VERSION" \
  -srcfolder "$PAYLOAD_DIR" \
  "$DMG_PATH"
/usr/bin/hdiutil verify "$DMG_PATH"

DMG_CHECKSUM="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
printf '%s  %s\n' "$DMG_CHECKSUM" "$DMG_NAME" >"$CHECKSUM_PATH"

echo "Created $DMG_PATH"
echo "Created $CHECKSUM_PATH"
