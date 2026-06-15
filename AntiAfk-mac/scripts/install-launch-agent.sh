#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PORT_DIR="$ROOT_DIR/macos-arm-port"
BINARY="$PORT_DIR/.build/arm64-apple-macosx/release/antiafk-rbx-mac"
LABEL="com.agzes.antiafk-rbx-mac"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -x "$BINARY" ]; then
  echo "Release binary not found. Building arm64 release first..."
  (cd "$PORT_DIR" && swift build -c release --arch arm64)
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BINARY</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/$LABEL.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/$LABEL.err.log</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Installed and loaded $LABEL"
echo "Logs:"
echo "  /tmp/$LABEL.out.log"
echo "  /tmp/$LABEL.err.log"
