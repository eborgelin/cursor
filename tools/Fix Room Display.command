#!/bin/bash
# Double-click: unmirror, 1080p/720p 1x, lock HDMI audio to 16-bit 48 kHz, select HDMI.
set -euo pipefail
SUPPORT="$HOME/Library/Application Support/FixRoomDisplay"
BIN="$SUPPORT/fix-room-display"
SRC="$SUPPORT/fix-room-display.swift"
if [[ -x "$BIN" ]]; then
  "$BIN"
elif [[ -f "$SRC" ]]; then
  /usr/bin/swift "$SRC"
else
  echo "The Fix Room Display helper is missing:"
  echo "  $SRC"
  read -r -n 1 -s -p "Press any key to close..."
  exit 1
fi
echo
read -r -n 1 -s -p "Press any key to close..."
echo
