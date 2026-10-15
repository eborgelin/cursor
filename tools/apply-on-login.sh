#!/bin/bash
# Silent apply for login / LaunchAgent. Retries while HDMI enumerates.
set +e
SUPPORT="$HOME/Library/Application Support/FixRoomDisplay"
SRC="$SUPPORT/fix-room-display.swift"
LOG="$HOME/Library/Logs/FixRoomDisplay.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "==== $(date) pid=$$ ===="
if [[ ! -f "$SRC" ]]; then
  echo "Missing $SRC"
  exit 1
fi
for _ in $(seq 1 15); do
  /usr/bin/swift "$SRC"
  code=$?
  if [[ $code -eq 0 ]]; then
    echo "apply exit 0"
    exit 0
  fi
  echo "apply exit $code; retry in 2s"
  sleep 2
done
echo "gave up after retries"
exit 1
