# AntiAFK-RBX macOS ARM Port Workspace

This workspace contains:

- `upstream/`: untouched clone of [Agzes/AntiAFK-RBX](https://github.com/Agzes/AntiAFK-RBX)
- `macos-arm-port/`: native Swift implementation for Apple Silicon Macs with CLI and SwiftUI app targets
- `scripts/`: launch agent install/uninstall helpers

Build the port:

```sh
cd macos-arm-port
swift build -c release --arch arm64
```

Build the user-friendly app:

```sh
scripts/build-app.sh
```

Open:

```text
dist/AntiAFK-RBX.app
```

Run it:

```sh
.build/arm64-apple-macosx/release/antiafk-rbx-mac
```

See `macos-arm-port/README.md` for options and macOS Accessibility setup.
