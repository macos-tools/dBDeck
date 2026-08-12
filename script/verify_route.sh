#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_DIR="$ROOT_DIR/.build/verification"
TEST_AUDIO="$VERIFY_DIR/route-test.aiff"
APP_BINARY="$VERIFY_DIR/dBDeck.app/Contents/MacOS/dBDeck"

mkdir -p "$VERIFY_DIR"
"$ROOT_DIR/script/build_and_run.sh" --stage

/usr/bin/say \
  -o "$TEST_AUDIO" \
  "dBDeck is verifying per application volume. This audio should become quieter and then stop."

/usr/bin/afplay "$TEST_AUDIO" &
AUDIO_PID=$!
trap 'kill "$AUDIO_PID" >/dev/null 2>&1 || true' EXIT
sleep 0.2

"$APP_BINARY" --verify-route "$AUDIO_PID"
