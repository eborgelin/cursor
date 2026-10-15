#!/bin/bash
# Combined interactive room check: displays, pick output, ding, hear-it prompt, optional Core Audio reset.
set +e
SRC="$HOME/Library/Application Support/FixRoomDisplay/room-presentation-check.swift"
FALLBACK="/Users/eborgeli/dev/cursor/tools/room-presentation-check.swift"
if [[ ! -f "$SRC" && -f "$FALLBACK" ]]; then
  SRC="$FALLBACK"
fi
if [[ ! -f "$SRC" ]]; then
  echo "Missing room-presentation-check.swift"
  read -r -n 1 -s -p "Press any key to close..."
  exit 1
fi
/usr/bin/swift "$SRC"
code=$?
echo
read -r -n 1 -s -p "Press any key to close..."
echo
exit $code
