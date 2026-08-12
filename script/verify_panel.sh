#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BINARY="$ROOT_DIR/dist/dBDeck.app/Contents/MacOS/dBDeck"

"$ROOT_DIR/script/build_and_run.sh" --stage
"$APP_BINARY" --verify-panel
