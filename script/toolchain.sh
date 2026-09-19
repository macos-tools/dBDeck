#!/usr/bin/env bash

# Selects the toolchain the build needs and exports DEVELOPER_DIR.
#
# `swift`, `xcrun` and `clang` in /usr/bin are shims. They pick a toolchain from
# DEVELOPER_DIR when it is set, and otherwise from the machine-wide choice that
# `xcode-select -p` reports. That machine-wide choice is frequently the Command
# Line Tools, which cannot build this project:
#
#   * it has no `actool`, so the asset catalog holding the app icon cannot be
#     compiled;
#   * it ships no SwiftUI macro plugins, so `@State` fails with "external macro
#     implementation type 'SwiftUIMacros.StateMacro' could not be found".
#
# The second failure surfaces as a compiler error deep in a build log with no
# hint that the toolchain is the problem, so this picks a complete Xcode itself
# and says so plainly when it cannot find one.
#
# Sourced rather than executed, so an already-exported DEVELOPER_DIR is honoured
# when it points at something usable.

dbdeck_toolchain_is_complete() {
  local developer_dir="$1"
  local plugins="Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"

  [[ -n "$developer_dir" ]] || return 1
  [[ -x "$developer_dir/usr/bin/actool" ]] || return 1
  [[ -e "$developer_dir/$plugins/libSwiftUIMacros.dylib" ]] || return 1
}

dbdeck_select_toolchain() {
  local candidate
  local -a candidates=()

  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    candidates+=("$DEVELOPER_DIR")
  fi
  if candidate="$(xcode-select -p 2>/dev/null)"; then
    candidates+=("$candidate")
  fi
  candidates+=(/Applications/Xcode.app/Contents/Developer)

  for candidate in "${candidates[@]}"; do
    if dbdeck_toolchain_is_complete "$candidate"; then
      export DEVELOPER_DIR="$candidate"
      return 0
    fi
  done

  {
    echo "dBDeck needs a full Xcode installation to build."
    echo
    echo "Checked, none of them complete:"
    for candidate in "${candidates[@]}"; do
      echo "  $candidate"
    done
    echo
    echo "The Command Line Tools alone are not enough: they have no actool for"
    echo "the app icon and no SwiftUI macro plugins, so @State does not compile."
    echo
    echo "Install Xcode, then point the machine at it:"
    echo "  sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    echo
    echo "Or build against one installed elsewhere:"
    # The outermost entry is the script the user actually ran, not this one.
    echo "  DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ${BASH_SOURCE[${#BASH_SOURCE[@]} - 1]}"
  } >&2
  return 1
}

dbdeck_select_toolchain
