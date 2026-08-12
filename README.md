# dBDeck（音枢）

dBDeck is a menu bar per-app audio controller for macOS 14.2 and later.

## Free MVP

- Remembers every identifiable app that has produced audio.
- Ranks playing apps first, then running apps with history, then stopped apps
  with history; each tier uses accumulated playback minutes.
- Shows the five highest-priority apps in its quick mixer.
- Adjusts each app from 0–100% without changing system volume.
- Mutes and unmutes individual apps.
- Remembers volume and mute state by bundle identifier.
- Runs as a menu-bar-only app with no Dock icon.

Launching the app opens its panel immediately. Opening it again, or clicking the
speaker icon in the menu bar, reopens the same panel. Background daemons, nested
helper apps, and raw process IDs are hidden or resolved to their containing
application. Apps that have never produced audio do not appear. Deleted apps are
filtered from the interface while their small history records remain stored.

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

This checks settings persistence, minute-level playback history and ranking,
real-time gain/mute sample processing, and Core Audio discovery against a real
audio-producing app.

To verify the complete signed Process Tap and aggregate-device route in a Debug
build, run:

```sh
./script/verify_route.sh
./script/verify_popover.sh
```

macOS asks for System Audio Recording permission the first time this route runs.

## Current scope

The free MVP follows the current default output device. Per-app device routing,
ducking, profiles, EQ, shortcuts, CLI, Shortcuts, and Raycast integration remain
future Pro work.
