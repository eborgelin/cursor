#!/bin/bash
# Build the menu-bar app with Apple's swiftc. No Homebrew packages.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc is not installed." >&2
  echo "Install Apple Command Line Tools (this is not a Homebrew formula):" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

APP="Apple HDMI Menu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O \
  -framework AppKit \
  -framework CoreAudio \
  -framework CoreGraphics \
  -framework Foundation \
  -o "$APP/Contents/MacOS/AppleHDMIMenu" \
  main.swift
cp Info.plist "$APP/Contents/Info.plist"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"
