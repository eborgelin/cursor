# HDMI audio I/O timeline never starts on M4 Pro (Mac16,8)

**Audience:** Apple Support / Core Audio / Display pipeline  
**Reporter:** Emil Borgelin  
**Date of investigation:** 22 Sep 2026 – 30 Sep 2026  
**OS at failure:** macOS 27.0 (build 26A428)  
**OS now:** macOS 27.0.1 (build 26A434)  
**Machine:** MacBook Pro, Model Identifier Mac16,8, Apple M4 Pro, 24 GB  
**Firmware at write-up:** 20457.1.29  

This package contains the diagnostic script used on the machine and a concise engineering summary. It does not include a sysdiagnose (too large; already collected separately on 22 Sep 2026).

---

## 1. What fails

When this MacBook Pro uses **HDMI as the default audio output**, video playback in **YouTube (Chrome)** and **embedded video in Microsoft PowerPoint** freezes the UI. Leaving slideshow with Esc, or switching Sound output back to **MacBook Pro Speakers**, recovers. Picture on the external display is otherwise fine.

This is **not** “no sound.” macOS lists the HDMI sink, can set it as default, and can change its physical stream format. Playback then blocks because Core Audio never starts I/O on that device.

The same failure occurred on:

- Cisco Webex room systems advertising HDMI audio as `CS-KITEQ-2` and `CS-KITMINI-1` (RoomOS / HDCP sinks)
- A **DELL S3221QS** 32" 4K monitor over HDMI (rules out Cisco-only EDID)

An older **M1 Pro (2021, HDMI 2.0)** used for the same presentations has **never** shown this. This M4 Pro uses a newer HDMI 2.1-class path (up to 8K60 / 4K240, HDMI-CEC).

Video **plays** when the default output is MacBook Pro Speakers while the same HDMI **picture** stays on the room/monitor. Moving sound to the laptop is not an acceptable presentation workflow.

---

## 2. Reproduction (confirmed)

Prerequisites: HDMI connected to an external sink that advertises audio (Dell or Cisco room). Do not start from a fresh boot if you want the **failing** state; the long-uptime session is important.

1. Boot and use the machine for days with HDMI occasionally connected (failing session had **14 days** uptime; WindowServer PID 605 from boot).
2. Connect HDMI. System Settings → Sound → select the HDMI device (e.g. `DELL S3221QS` or `CS-…`).
3. Play YouTube or a PowerPoint embedded movie.

**Expected:** video and audio on the external sink.  
**Actual:** UI/video freeze. Esc or switching to built-in speakers recovers.

Audio-only confirmation (no video required):

```bash
# After selecting HDMI as default output:
afplay -t 2 /System/Library/Sounds/Glass.aiff
```

**Actual:** `Error: AudioQueueStart failed ('stop')` and exit status 1. No frames reach the sink.

---

## 3. Core Audio evidence (30 Sep 2026, ~13:44 local)

HDMI device UUID in HAL: `10AC05D1-0000-0000-1A1F-010380462878` (device id 54).  
`killall coreaudiod` (admin) **did** restart the daemon (new PID 81166) and **did** set HDMI as default. `afplay` still failed.

Representative log lines:

```
HALS_IOEngine2::_StartIO(49) succeeded on Context 702  new state: … State: Running
AudioConverter … Float32 interleaved → Int16 interleaved   # 16-bit HDMI path
…
IsTimeRunning_Helper: Device 10AC05D1-… is not running.
IOWorkLoop: could not establish a timeline after waiting 10000000 microseconds
IO Stopped Context 702 after 0 frames.
IOWorkLoopDeinit: … stopping with error 1937010544
StartIOThread: the IO thread failed to start, Error: 1937010544
HALC_ProxyIOContext::IOWorkLoop: the server failed to start, Error: 0x73746F70
AudioDeviceStart (err 1937010544)
```

`1937010544` is FourCC **`'stop'`** (`0x73746F70`).

Chrome’s sandboxed audio utility (`audio.mojom.AudioService`) hit the **same** timeline failure on the same device a few seconds later. This is not an `afplay`-only client bug.

Physical formats tried while HDMI was selected (all set successfully, all failed to start I/O):

| Physical format        | `AudioObjectSetPropertyData` | `afplay` |
|------------------------|------------------------------|----------|
| 48 kHz, 2 ch, 16-bit   | succeeded                    | `'stop'` |
| 44.1 kHz, 2 ch, 16-bit | succeeded                    | `'stop'` |
| 48 kHz, 2 ch, 24-bit   | succeeded                    | `'stop'` |

The Dell advertised LPCM 16/20/24-bit at 32 / 44.1 / 48 kHz stereo. Locking to 16-bit 48 kHz is **not** sufficient once the HDMI I/O clock is dead.

---

## 4. What did **not** fix a wedged session

- Switching HDMI sample/bit depth in Core Audio
- `killall coreaudiod` / LaunchAgent restart (SIP blocks `launchctl kickstart` of `com.apple.audio.coreaudiod`; admin `killall` ran and still failed)
- Forcing 1080p / 720p 1x on the sink (helpful as a composition precaution; not the cure)
- USB-C vs built-in HDMI was not required for the Dell repro (native HDMI to Dell)

There is **no user-replaceable HDMI kext** on Apple Silicon. SIP is on. No DisplayLink / BetterDisplay.

---

## 5. What **did** restore HDMI audio

**Reboot with the HDMI cable already plugged into the sink**, then log in **before** starting Chrome or PowerPoint, then select HDMI and play a system sound.

After that reboot (30 Sep 2026 13:53):

- `DELL S3221QS` native **4K 1x** (`3840x2160 @ 60 Hz`, UI looks like 3840x2160 — **not** HiDPI “looks like 1080p”)
- Default output: `DELL S3221QS`, transport HDMI, 48 kHz, **16-bit**
- `afplay` succeeded; YouTube / PowerPoint played with monitor sound

Changing the display back to 4K 1x after a 1080p test **kept working**. The reboot-with-sink-attached is the actual recovery, not 1080p.

Earlier failing layout on the same Dell was often **4K HiDPI** (`3840x2160` pixels, UI 1920x1080). That is a different WindowServer composition path and may aggravate decode, but HDMI I/O `'stop'` happened even on an audio-only `afplay` with no video.

---

## 6. Working theory (for Core Audio / DCP)

On this M4 Pro, HDMI **audio** is clocked from the **display** pipeline. After long uptime, hotplug, or a previous failed StartIO, HAL still publishes the HDMI device and accepts format/default-output changes, but the IO engine never establishes a timeline (`IsTimeRunning` false, 10 s wait, 0 frames, `'stop'`). Clients (`afplay`, Chrome, PowerPoint) wait on `AudioQueueStart` / `AudioDeviceStart` and the UI appears frozen.

Built-in speakers bypass that clock, so video decode proceeds.

This matches a presentation-only machine: the customer cannot leave audio on the laptop when presenting to a room.

---

## 7. What the attached script does (workaround / diagnostic, not a driver)

`Check Room Audio.command` runs `room-presentation-check.swift` with `/usr/bin/swift` (no third-party tools).

On launch it:

1. Prints builtin vs external display mode (mirroring / HiDPI vs 1x). Optionally **unmirrors**; it does **not** force 1080p (native 4K 1x is valid).
2. Lists Core Audio **output** devices with transport type (HDMI, DisplayPort, USB, Built-in, Bluetooth, Virtual) and lets the user pick one. HDMI/DP/room-like names are recommended.
3. For HDMI/DP, sets physical format to **2 ch / 16-bit / 48 kHz** when that format exists (fallback 16-bit 44.1 kHz).
4. Sets default and system output to the chosen device.
5. Plays `/System/Library/Sounds/Glass.aiff` via `afplay -t 2`.
6. Asks whether the **room** heard the ding.
7. If not, offers `osascript` → `killall coreaudiod` (admin password) and retries.
8. On continued failure, offers to switch default output to **MacBook Pro Speakers** so video will not freeze, and tells the user to reboot with the cable attached.

This is how we proved: format set succeeds, `AudioQueueStart` fails, Core Audio restart is insufficient, reboot-with-HDMI-connected restores I/O.

Public APIs used: CoreAudio HAL (`AudioObjectGetPropertyData` / `SetPropertyData`, `kAudioStreamPropertyPhysicalFormat`, `kAudioHardwarePropertyDefaultOutputDevice`), CoreGraphics display mirroring, `afplay`, `osascript` admin `killall coreaudiod`.

---

## 8. Ask of Apple

1. Confirm whether this is a known Core Audio / HDMI / DCP defect on M4 Pro (Mac16,8) vs M1 Pro HDMI 2.0.
2. Fix StartIO so HDMI audio can establish a timeline after hotplug / long uptime without requiring a full reboot with the sink attached.
3. If a sysdiagnose is needed on a **failing** (pre-reboot) session, we can recapture while `afplay` returns `'stop'`. The 22 Sep 2026 sysdiagnose covered Cisco room freezes the same day. A second failing-session sysdiagnose is **15 Oct 2026 10:33** (build 26A434), taken while HDMI I/O was still `'stop'` (see §9).

Please attach this zip to the case. Run the script on a comparable M4 Pro with HDMI audio to reproduce without PowerPoint.

---

## 9. Recurrence — 15 Oct 2026 (Cisco Board 55)

Sysdiagnose: `sysdiagnose_2026.10.15_10-33-11+0200_1417_macOS_Mac_26A434` (keychord, macOS 27.0.1 26A434).  
Boot: 6 Oct 2026 (~8 days 21 hours). `coreaudiod` PID **717** from that boot until the script killed it at 10:31.

**Sink:** `CS-BOARD55P-2` (Cisco Board, vendor id `d33`, product `109`), HDMI UUID `0D330901-0000-0000-0720-0103807A4578`.  
Display at capture: **3840×2160 pixels, UI 1920×1080 @ 30 Hz, HiDPI, `spdisplays_television`**. Physical HDMI audio already **2 ch / 48 kHz / Int16**.

Same HAL failure as 30 Sep, now with PowerPoint as the client:

```
10:28:44  PowerPoint FigAudioQueueStart2 / AudioQueueStartWithFlags
10:28:54  could not establish a timeline after waiting 10000000 microseconds
          IO Stopped Context 7761 after 0 frames
          error 1937010544 ('stop')
          HALC_ProxyIOContext::IOWorkLoop: the server failed to start, Error: 0x73746F70
          PowerPoint: audio queue failed to start with error 1937010544 = 'stop'
```

The UI freeze is that **10 second** StartIO wait. Repeated at 10:29:21. Earlier the same morning (08:45) the same UUID already failed StartIO, including `no master engine info` / `StopIO … Error: 0x73746F70`.

**Script at 10:31–10:32:** `killall coreaudiod` → new PID **2657**. HDMI HAL id changed **207 → 112 → 52** (same UUID). `afplay` still `'stop'`. Webex also `'stop'` on the same device. Invalid stream virtual format **sample rate 0** on streams 104/105 in the post-restart dump.

Conclusion: Core Audio restart **still does not** restore HDMI I/O on a long-uptime M4 Pro, including a new Cisco Board with 1080p30 TV EDID. Workaround remains reboot with HDMI attached. The diagnostic script now also treats 30 Hz / HiDPI as unsafe and relocates the HDMI device **by name** after a restart because HAL ids change.
