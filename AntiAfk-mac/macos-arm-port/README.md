# AntiAFK-RBX macOS ARM Port

Native macOS/Apple Silicon port inspired by [Agzes/AntiAFK-RBX](https://github.com/Agzes/AntiAFK-RBX).

The upstream app is a Windows Win32 tray utility. This port keeps the core anti-idle behavior and implements it with macOS-native Swift APIs:

- provides a clickable macOS app with a SwiftUI window
- detects a running Roblox process
- sends configurable anti-idle actions on an interval
- supports `space`, `w+s`, and `i+o` zoom actions
- cycles through multiple Roblox processes when multi-instance support is enabled
- throttles Roblox CPU usage for a session-only FPS cap effect
- can keep the Mac awake while the tool is running
- can optionally activate Roblox before sending input
- builds as an arm64 macOS command-line tool

## Requirements

- Apple Silicon Mac
- macOS 13 or newer
- Xcode Command Line Tools
- Accessibility permission for the built binary or Terminal app

Install the command line tools if needed:

```sh
xcode-select --install
```

## Build The App

From the repository root:

```sh
scripts/build-app.sh
```

The app bundle will be created at:

```text
dist/AntiAFK-RBX.app
```

Open it from Finder. Click `Open Accessibility` in the app if macOS has not granted permission yet, then enable `AntiAFK-RBX` in:

```text
System Settings > Privacy & Security > Accessibility
```

If macOS already shows `AntiAFK-RBX` as enabled but the app still asks for permission, remove the old `AntiAFK-RBX` entry from Accessibility, open the rebuilt app once, then add the app again. The bundle intentionally keeps the simple `AntiAFK-RBX` identity because that matches the earlier build macOS accepted.

The app treats Accessibility status as advisory. `Start` and `Test Once` still run if macOS reports permission as unverified, which avoids false TCC failures blocking an otherwise approved app.

## App Features

- Main: start/stop anti-AFK, choose action, target, interval, and focus behavior.
- Advanced: enable multi-instance cycling, set per-instance delay, and apply CPU-based FPS throttling.
- Utils: launch another Roblox instance and refresh detected client count.
- Logs: inspect recent app actions and setup messages.

The FPS limiter is session-only. It throttles Roblox by briefly pausing/resuming Roblox processes to reduce CPU usage and approximate a lower FPS. It does not edit `ClientAppSettings.json`, and it takes effect immediately.

## Build

```sh
cd macos-arm-port
swift build -c release --arch arm64
```

The binary will be created at:

```sh
.build/arm64-apple-macosx/release/antiafk-rbx-mac
```

## Run

```sh
.build/arm64-apple-macosx/release/antiafk-rbx-mac
```

Useful examples:

```sh
# Send Space every 9 minutes when Roblox is open.
antiafk-rbx-mac --interval 540 --action space

# Send W then S every 5 minutes.
antiafk-rbx-mac --interval 300 --action ws

# Activate Roblox before each action if background events are ignored.
antiafk-rbx-mac --foreground

# Send one test action and exit.
antiafk-rbx-mac --once --verbose
```

## Accessibility Permission

macOS blocks synthetic input until you grant permission.

Open:

```text
System Settings > Privacy & Security > Accessibility
```

Enable the terminal app you run this from, or enable the built `antiafk-rbx-mac` binary directly.

## Install As A Login Agent

From this repository root:

```sh
scripts/install-launch-agent.sh
```

Unload it later with:

```sh
scripts/uninstall-launch-agent.sh
```

The launch agent runs the release binary with default options. Rebuild after changes:

```sh
cd macos-arm-port
swift build -c release --arch arm64
```

## Differences From Windows AntiAFK-RBX

This port does not include the Windows tray UI, Bloxstrap integration, Win32 window layout tools, Discord webhooks, or Windows mutex-based multi-instance controls. Those features depend on Windows-only APIs or Windows Roblox ecosystem tools.

For macOS, the practical native replacement is a SwiftUI app that uses Accessibility, CoreGraphics events, CPU throttling, and macOS launch requests.

## License

MIT. See the upstream repository license and the copied license in this workspace.
