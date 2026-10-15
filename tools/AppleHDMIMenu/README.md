# Apple HDMI Menu

Menu-bar watcher for the M4 Pro HDMI audio clock. It stays idle until an external display is connected and an HDMI audio device appears, runs one silent clock test, then waits again.

The menu-bar icon stays hidden when HDMI is absent or the clock is fine. A dead clock shows an HDMI symbol with a red X. Hover that icon for the restart instruction.

Left-click and right-click open the same menu:

- **Hide icon when there is no HDMI or no issue** (on by default)
- **Quit**

The dead-clock icon stays visible even when hiding is on. Opening the app again while the icon is hidden shows the menu so you can still quit.

## Tools

No Homebrew packages. AppKit and Core Audio ship with macOS. The Homebrew `swift` formula does not include the macOS SDK, so it cannot build this app.

1. Install Homebrew only if `brew` is missing. Compiling does not need it.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

2. Install Apple’s Command Line Tools. This provides `swiftc` and the macOS SDK. It is not a Brew formula.

```bash
xcode-select --install
```

Click Install, then check:

```bash
xcode-select -p
swiftc --version
```

`xcode-select -p` should print a path under `/Library/Developer/CommandLineTools` or Xcode. `swiftc` should print a Swift version.

3. Build and open:

```bash
cd /Users/eborgeli/dev/cursor/tools/AppleHDMIMenu
./build.sh
open "Apple HDMI Menu.app"
```

`build.sh` runs `swiftc -O` and links only AppKit, CoreAudio, CoreGraphics, and Foundation. It then runs `codesign --sign -` so macOS will open the app. That is a local ad-hoc signature, not a certificate and not a Homebrew package.
