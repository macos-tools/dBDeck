#!/usr/bin/env bash
set -euo pipefail

# Builds one DMG per architecture. Each carries a thin binary, so a download
# contains only the code the machine it lands on can actually run.

APP_NAME="dBDeck"
RELEASE_VERSION="${1:-0.2.0}"
ARCHITECTURES=(arm64 x86_64)

if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "usage: $0 [numeric-version, for example 0.2.0]" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

mkdir -p "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.dBDeck-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

for ARCH in "${ARCHITECTURES[@]}"; do
  APP_BUNDLE="$ROOT_DIR/.build/verification/release/$ARCH/$APP_NAME.app"
  APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
  DMG_NAME="$APP_NAME-$RELEASE_VERSION-$ARCH.dmg"
  DMG_PATH="$DIST_DIR/$DMG_NAME"
  CHECKSUM_PATH="$DMG_PATH.sha256"

  DBDECK_APP_VERSION="$RELEASE_VERSION" \
    "$ROOT_DIR/script/build_and_run.sh" --release-stage "$ARCH"

  /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
  /usr/bin/plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null
  /usr/bin/lipo "$APP_BINARY" -verify_arch "$ARCH"

  BUILT_ARCHS="$(/usr/bin/lipo -archs "$APP_BINARY")"
  if [[ "$BUILT_ARCHS" != "$ARCH" ]]; then
    echo "$DMG_NAME: expected $ARCH alone, built $BUILT_ARCHS" >&2
    exit 1
  fi

  PAYLOAD_DIR="$STAGING_DIR/$ARCH"
  mkdir -p "$PAYLOAD_DIR"
  /usr/bin/ditto "$APP_BUNDLE" "$PAYLOAD_DIR/$APP_NAME.app"
  ln -s /Applications "$PAYLOAD_DIR/Applications"

  /usr/bin/hdiutil create \
    -ov \
    -format UDZO \
    -volname "$APP_NAME $RELEASE_VERSION ($ARCH)" \
    -srcfolder "$PAYLOAD_DIR" \
    "$DMG_PATH"
  /usr/bin/hdiutil verify "$DMG_PATH"

  DMG_CHECKSUM="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
  printf '%s  %s\n' "$DMG_CHECKSUM" "$DMG_NAME" >"$CHECKSUM_PATH"

  echo "Created $DMG_PATH"
  echo "Created $CHECKSUM_PATH"
done
