#!/bin/bash
# Portable launcher for Apple Support / local use. Runs the Swift checker beside this file.
set +e
cd "$(dirname "$0")"
SRC="$(pwd)/room-presentation-check.swift"
if [[ ! -f "$SRC" ]]; then
  echo "Missing room-presentation-check.swift next to this launcher."
  read -r -n 1 -s -p "Press any key to close..."
  exit 1
fi
echo "Room presentation check"
echo "Source: $SRC"
echo
/usr/bin/swift "$SRC"
code=$?
echo
read -r -n 1 -s -p "Press any key to close..."
echo
exit $code
