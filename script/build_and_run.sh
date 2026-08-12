#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="dBDeck"
BUNDLE_ID="com.dbdeck.app"
MIN_SYSTEM_VERSION="14.2"
CONTROL_NAME="dBDeckControls"
CONTROL_BUNDLE_ID="$BUNDLE_ID.controls"
CONTROL_MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
CONTROL_BUNDLE="$APP_CONTENTS/PlugIns/$CONTROL_NAME.appex"
CONTROL_CONTENTS="$CONTROL_BUNDLE/Contents"
CONTROL_MACOS="$CONTROL_CONTENTS/MacOS"
CONTROL_BINARY="$CONTROL_MACOS/$CONTROL_NAME"
CONTROL_INFO_PLIST="$CONTROL_CONTENTS/Info.plist"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build --disable-sandbox --product "$APP_NAME"
BUILD_BINARY="$(swift build --disable-sandbox --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$CONTROL_MACOS"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

CONTROL_SDK="$(DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" /usr/bin/xcrun --sdk macosx --show-sdk-path)"
CONTROL_SWIFTC="$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
CONTROL_ARCH="$(uname -m)"
"$CONTROL_SWIFTC" \
  -sdk "$CONTROL_SDK" \
  -target "$CONTROL_ARCH-apple-macos$CONTROL_MIN_SYSTEM_VERSION" \
  -module-cache-path "$ROOT_DIR/.build/control-module-cache" \
  -parse-as-library \
  -application-extension \
  -Xlinker -e \
  -Xlinker _NSExtensionMain \
  -framework AppIntents \
  -framework Foundation \
  -framework SwiftUI \
  -framework WidgetKit \
  "$ROOT_DIR/Extensions/dBDeckControls/dBDeckControls.swift" \
  -o "$CONTROL_BINARY"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>dBDeck</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>com.dbdeck.app.mixer</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>dbdeck</string>
      </array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAudioCaptureUsageDescription</key>
  <string>dBDeck needs access to system audio to adjust each app's volume on this Mac.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>dBDeck uses macOS audio capture permission only to process app audio locally.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

cat >"$CONTROL_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>dBDeck Controls</string>
  <key>CFBundleExecutable</key>
  <string>$CONTROL_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$CONTROL_BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$CONTROL_NAME</string>
  <key>CFBundlePackageType</key>
  <string>XPC!</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$CONTROL_MIN_SYSTEM_VERSION</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST

codesign --force --sign - \
  --entitlements "$ROOT_DIR/Resources/dBDeckControls.entitlements" \
  "$CONTROL_BUNDLE"
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/dBDeck.entitlements" "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
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
  --stage|stage)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--stage]" >&2
    exit 2
    ;;
esac
