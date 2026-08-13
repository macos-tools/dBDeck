# dBDeck

**Simplified Chinese: 音量岛** · [简体中文](README.zh-CN.md)

dBDeck is a lightweight per-app volume controller for the macOS menu bar. It
supports macOS 14.2 and later.

> dBDeck is currently an early, source-only release. The repository does not yet
> provide a notarized app for end users.

## Features

- Adjust each app from 0% to 200% without changing the system volume.
- Mute and unmute individual apps.
- Remember volume and mute state by bundle identifier.
- Remember identifiable apps that have produced audio across launches.
- Rank playing apps first, then running apps with playback history, then stopped
  apps with history. Each group is ordered by accumulated playback time.
- Show the eligible apps in a scrollable menu bar mixer with no Dock icon.
- Use English or Simplified Chinese automatically, following the macOS language.

Apps that have never produced audio do not appear. Background services, nested
helper apps, and raw process IDs are hidden or resolved to their containing app.
Deleted apps are filtered from the mixer while their small history records remain
stored. When more than ten installed apps have history, stopped entries that have
not played for over seven days are hidden by maintenance that runs at most once a
day.

At the default 100% volume with mute off, dBDeck removes its audio-processing
route and lets audio pass through normally.

## Privacy and permission

dBDeck does not record, store, or transmit audio. It has no networking feature.
Audio processing stays on the Mac.

The app stores the following data locally in `UserDefaults`:

- Bundle identifier, display name, and last known app path.
- Accumulated playback seconds and the most recent playback date.
- Per-app volume and mute state.
- Which dormant records are hidden and when list maintenance last ran.

dBDeck uses Apple's Core Audio Process Tap API, a private aggregate device, and a
real-time gain callback. macOS requests **System Audio Recording** permission when
an app is muted or set to a volume other than 100%. The 100% unmuted state does
not keep a processing route active.

## Requirements

- macOS 14.2 or later.
- Xcode 16 or a compatible Swift 6 toolchain.

## Build and run

```sh
./script/build_and_run.sh
```

The script builds `dist/dBDeck.app`, applies an ad-hoc signature for local
development, and launches it. This build is not Developer ID signed or notarized
and is not intended for distribution.

Optional modes:

```sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --debug
```

## Test

```sh
./script/test.sh
```

The test script runs the Swift package tests for settings persistence, playback
history and ranking, store state transitions, localized app names, and real-time
gain/mute sample processing. It also verifies Core Audio discovery against a real
audio-producing fixture app. It does not stop an already running dBDeck instance.

To verify the complete Process Tap and aggregate-device route in a Debug build:

```sh
./script/verify_route.sh
```

macOS requests System Audio Recording permission the first time this route runs.
The route check covers discovery, Process Tap creation, gain changes, mute, and
cleanup. The AudioDSP tests separately assert exact sample values.

## Implementation

- SwiftUI `MenuBarExtra` for the system-managed menu bar item and mixer.
- Core Audio Process Tap and a private aggregate device for per-app processing.
- A small C real-time callback with atomic gain state for sample processing.
- Local JSON-encoded playback history and volume preferences in `UserDefaults`.

## Current scope

The current version follows the system's default output device. Per-app output
device routing, automatic ducking, profiles, EQ, global shortcuts, CLI, Shortcuts,
and Raycast integration are not included.

## Contributing

Bug reports and focused pull requests are welcome. Please run `./script/test.sh`
before submitting a code change.

## License

dBDeck is licensed under the [GNU General Public License version 3
only](LICENSE) (`GPL-3.0-only`).
