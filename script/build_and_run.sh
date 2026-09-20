#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
RELEASE_ARCH="${2:-}"
APP_NAME="dBDeck"
BUNDLE_ID="com.dbdeck.mac"
MIN_SYSTEM_VERSION="14.2"
APP_VERSION="${DBDECK_APP_VERSION:-0.2.2}"
BUILD_NUMBER="${DBDECK_BUILD_NUMBER:-9}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain.sh"
DIST_DIR="$ROOT_DIR/dist"
VERIFY_DIR="$ROOT_DIR/.build/verification"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--stage|stage|--release-stage|release-stage)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--stage|--release-stage <arch>]" >&2
    exit 2
    ;;
esac

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || return 0

  for _ in {1..50}; do
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done

  echo "$APP_NAME did not terminate; refusing to replace its running app bundle" >&2
  exit 1
}

case "$MODE" in
  --stage|stage)
    APP_BUNDLE="$VERIFY_DIR/$APP_NAME.app"
    ;;
  --release-stage|release-stage)
    # Release builds are per architecture, one thin binary each, so a download
    # carries only the code the machine can run.
    case "$RELEASE_ARCH" in
      arm64|x86_64) ;;
      *)
        echo "usage: $0 --release-stage <arm64|x86_64>" >&2
        exit 2
        ;;
    esac
    APP_BUNDLE="$VERIFY_DIR/release/$RELEASE_ARCH/$APP_NAME.app"
    ;;
  *)
    stop_app
    APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
    ;;
esac

cd "$ROOT_DIR"
if [[ "$MODE" == "--release-stage" || "$MODE" == "release-stage" ]]; then
  RELEASE_BUILD_DIR="$ROOT_DIR/.build/release-$RELEASE_ARCH"
  RELEASE_TRIPLE="$RELEASE_ARCH-apple-macosx$MIN_SYSTEM_VERSION"

  swift build \
    --disable-sandbox \
    --configuration release \
    --triple "$RELEASE_TRIPLE" \
    --scratch-path "$RELEASE_BUILD_DIR" \
    --product "$APP_NAME"
  BUILD_BINARY="$(swift build \
    --disable-sandbox \
    --configuration release \
    --triple "$RELEASE_TRIPLE" \
    --scratch-path "$RELEASE_BUILD_DIR" \
    --show-bin-path)/$APP_NAME"
else
  swift build --disable-sandbox --product "$APP_NAME"
  BUILD_BINARY="$(swift build --disable-sandbox --show-bin-path)/$APP_NAME"
fi

mkdir -p "$(dirname "$APP_BUNDLE")"
STAGING_DIR="$(mktemp -d "$(dirname "$APP_BUNDLE")/.dBDeck-stage.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

STAGED_APP="$STAGING_DIR/$APP_NAME.app"
STAGED_CONTENTS="$STAGED_APP/Contents"
STAGED_MACOS="$STAGED_CONTENTS/MacOS"
STAGED_RESOURCES="$STAGED_CONTENTS/Resources"
STAGED_BINARY="$STAGED_MACOS/$APP_NAME"
STAGED_INFO_PLIST="$STAGED_CONTENTS/Info.plist"
ASSET_CATALOG="$ROOT_DIR/Resources/Assets.xcassets"

mkdir -p "$STAGED_MACOS" "$STAGED_RESOURCES"
cp "$BUILD_BINARY" "$STAGED_BINARY"
cp "$ROOT_DIR/Resources/dBDeckMenuBarIcon.svg" "$STAGED_RESOURCES/dBDeckMenuBarIcon.svg"
cp -R "$ROOT_DIR/Resources/Localization/." "$STAGED_RESOURCES/"
chmod +x "$STAGED_BINARY"

ASSET_OUTPUT="$STAGING_DIR/asset-output"
mkdir -p "$ASSET_OUTPUT"
xcrun actool \
  "$ASSET_CATALOG" \
  --compile "$ASSET_OUTPUT" \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --app-icon AppIcon \
  --output-partial-info-plist "$STAGING_DIR/asset-info.plist" \
  --warnings \
  --errors
cp "$ASSET_OUTPUT/AppIcon.icns" "$STAGED_RESOURCES/AppIcon.icns"
cp "$ASSET_OUTPUT/Assets.car" "$STAGED_RESOURCES/Assets.car"

cat >"$STAGED_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>dBDeck</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>dBDeck needs access to system audio to adjust each app's volume on this Mac.</string>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 linger. Licensed under the Apache License 2.0.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/dBDeck.entitlements" "$STAGED_APP"

PREVIOUS_CONTENTS="$STAGING_DIR/previous-Contents"
mkdir -p "$APP_BUNDLE"
if [[ -e "$APP_BUNDLE/Contents" ]]; then
  mv "$APP_BUNDLE/Contents" "$PREVIOUS_CONTENTS"
fi
if ! mv "$STAGED_CONTENTS" "$APP_BUNDLE/Contents"; then
  if [[ -e "$PREVIOUS_CONTENTS" ]]; then
    mv "$PREVIOUS_CONTENTS" "$APP_BUNDLE/Contents"
  fi
  exit 1
fi

APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

open_app() {
  /usr/bin/open "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 3
    APP_PID="$(pgrep -x "$APP_NAME")"
    test -n "$APP_PID"
    echo "$APP_NAME is running (PID $APP_PID)"
    ;;
  --stage|stage|--release-stage|release-stage)
    ;;
esac
