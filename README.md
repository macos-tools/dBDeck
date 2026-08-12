# dBDeck（音枢）

dBDeck is a per-app audio controller for macOS. Its Control Center integration
requires macOS 26 or later.

## Free MVP

- Remembers every identifiable app that has produced audio.
- Ranks playing apps first, then ranks history by accumulated playback minutes.
- Shows the five highest-priority apps in its quick mixer.
- Adjusts each app from 0–100% without changing system volume.
- Mutes and unmutes individual apps.
- Remembers volume and mute state by bundle identifier.
- Runs without a persistent menu bar or Dock icon.

The macOS 26 WidgetKit control uses a speaker icon in Control Center. Activating
it opens the quick mixer near Control Center. Background daemons, nested helper
apps, and raw process IDs are hidden or resolved to their containing application.
Apps that have never produced audio do not appear.

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
./script/verify_panel.sh
./script/verify_control.sh
```

macOS asks for System Audio Recording permission the first time this route runs.

## Current scope

The free MVP follows the current default output device. Per-app device routing,
ducking, profiles, EQ, shortcuts, CLI, Shortcuts, and Raycast integration remain
future Pro work.
