# dBDeck（音枢）

dBDeck is a menu bar per-app audio controller for macOS 14.2 and later.

## Free MVP

- Remembers every identifiable app that has produced audio.
- Ranks playing apps first, then running apps with history, then stopped apps
  with history; each tier uses persisted playback seconds.
- Shows all eligible apps in a scrollable quick mixer.
- Adjusts each app from 0–200% without changing system volume.
- Mutes and unmutes individual apps.
- Remembers volume and mute state by bundle identifier.
- Runs as a menu-bar-only app with no Dock icon.

Launching the app installs its system-managed menu bar item. Clicking its
three-fader icon opens the mixer panel. Background daemons, nested
helper apps, and raw process IDs are hidden or resolved to their containing
application. Apps that have never produced audio do not appear. Deleted apps are
filtered from the interface while their small history records remain stored.
When more than 10 installed apps have history, dormant entries older than seven
days are hidden by maintenance that runs at most once per day.

Audio stays on the Mac. dBDeck uses Apple's Core Audio Process Tap API, a private
aggregate device, and a real-time gain callback. The first adjustment requires
macOS System Audio Recording permission.

## Build and run

```sh
./script/build_and_run.sh
```

The script builds a signed development app at `dist/dBDeck.app` and launches it.
The Codex Run button uses the same command.

Optional modes:

```sh
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --debug
```

## Verify

```sh
./script/test.sh
```

This runs the standard Swift package test targets for settings persistence,
second-level playback history and ranking, Store state transitions, localized
application names, and real-time gain/mute sample processing. It then verifies
Core Audio discovery against a real audio-producing app. The script does not stop
an already running dBDeck instance.

To verify the complete signed Process Tap and aggregate-device route in a Debug
build, run:

```sh
./script/verify_route.sh
```

macOS asks for System Audio Recording permission the first time this route runs.
The route check verifies discovery plus Process Tap creation, gain changes, mute,
and cleanup; exact sample values are asserted separately by the AudioDSP tests.

## Current scope

The free MVP follows the current default output device. Per-app device routing,
ducking, profiles, EQ, shortcuts, CLI, Shortcuts, and Raycast integration remain
future Pro work.
