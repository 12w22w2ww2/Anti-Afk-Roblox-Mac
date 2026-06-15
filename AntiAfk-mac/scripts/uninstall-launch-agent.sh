#!/bin/sh
set -eu

LABEL="com.agzes.antiafk-rbx-mac"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Uninstalled $LABEL"
else
  echo "$LABEL is not installed"
fi
