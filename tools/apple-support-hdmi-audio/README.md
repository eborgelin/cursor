# Check Room Audio — Apple Support package

## Run on macOS (Apple Silicon)

1. Unzip this folder.
2. Right-click **Check Room Audio.command** → Open (first time only, if Gatekeeper asks).
3. Plug in HDMI to a monitor or room system that has speakers **before** opening Chrome or PowerPoint.
4. Follow the Terminal prompts: pick the HDMI/room output, listen for the ding, answer whether the room heard it.

Requires `/usr/bin/swift` (Xcode Command Line Tools or full Xcode).

## Files

| File | Role |
|------|------|
| `APPLE-SUPPORT-BRIEF.md` | Engineering summary, logs, repro, workaround |
| `room-presentation-check.swift` | Combined diagnostic (display info, device picker, 16/48 lock, ding, Core Audio reset) |
| `Check Room Audio.command` | Double-click launcher; runs the Swift file next to it |
| `hdmi-audio-validate.swift` | Non-interactive 16/48 + `afplay` helper (`--stay` to leave HDMI selected) |

## Capture logs if `afplay` fails

```bash
/usr/bin/log show --last 10m --info --predicate \
  'process == "coreaudiod" OR process == "afplay" OR eventMessage CONTAINS "1937010544" OR eventMessage CONTAINS "timeline"'
```

Look for `'stop'` / `1937010544` / `could not establish a timeline` / `0 frames`.
