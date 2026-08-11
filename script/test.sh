#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_DIR="$ROOT_DIR/.build/verification"
VERIFY_BINARY="$VERIFY_DIR/verify-volume-preferences"
DSP_VERIFY_BINARY="$VERIFY_DIR/verify-audio-dsp"
DISCOVERY_VERIFY_BINARY="$VERIFY_DIR/verify-audio-discovery"

mkdir -p "$VERIFY_DIR/module-cache"

swiftc \
  -module-cache-path "$VERIFY_DIR/module-cache" \
  "$ROOT_DIR/Sources/dBDeck/Models/AppVolumeSetting.swift" \
  "$ROOT_DIR/Sources/dBDeck/Stores/VolumePreferences.swift" \
  "$ROOT_DIR/Tests/dBDeckTests/VolumePreferencesTests.swift" \
  -o "$VERIFY_BINARY"

"$VERIFY_BINARY"

clang \
  -std=c11 \
  -I "$ROOT_DIR/Sources/AudioDSP/include" \
  "$ROOT_DIR/Sources/AudioDSP/AudioDSP.c" \
  "$ROOT_DIR/Tests/AudioDSPTests/AudioDSPVerifier.c" \
  -framework CoreAudio \
  -o "$DSP_VERIFY_BINARY"

"$DSP_VERIFY_BINARY"

swiftc \
  -module-cache-path "$VERIFY_DIR/module-cache" \
  -framework AppKit \
  -framework CoreAudio \
  "$ROOT_DIR/Sources/dBDeck/Models/AudioApp.swift" \
  "$ROOT_DIR/Sources/dBDeck/Support/CoreAudioSupport.swift" \
  "$ROOT_DIR/Sources/dBDeck/Services/AudioProcessDiscovery.swift" \
  "$ROOT_DIR/Tests/dBDeckTests/AudioDiscoveryVerifier.swift" \
  -o "$DISCOVERY_VERIFY_BINARY"

while true; do
  /usr/bin/afplay /System/Library/Sounds/Glass.aiff
done >/dev/null 2>&1 &
AUDIO_LOOP_PID=$!
trap 'kill "$AUDIO_LOOP_PID" >/dev/null 2>&1 || true' EXIT
sleep 0.2
"$DISCOVERY_VERIFY_BINARY"
