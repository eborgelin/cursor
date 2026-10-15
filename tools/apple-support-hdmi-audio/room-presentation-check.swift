import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// Interactive room-presentation check: unmirror if needed, pick an
/// output device, lock HDMI/DP to 16-bit 48 kHz, play a ding, and ask
/// whether the room speakers heard it.
///
/// After 15 Oct 2026 (Cisco CS-BOARD55P-2): also treat 1080p30 / 4K-HiDPI
/// TV EDID as unsafe, relocate HDMI by name after coreaudiod restart
/// (HAL ids change), and escalate to reboot-with-cable-in when I/O
/// returns 'stop' on a long-uptime session.

func addr(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("ERROR: \(message)\n", stderr)
    exit(code)
}

func prompt(_ message: String) -> String {
    print(message, terminator: " ")
    fflush(stdout)
    return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func askYesNo(_ message: String, defaultYes: Bool = true) -> Bool {
    let hint = defaultYes ? "[Y/n]" : "[y/N]"
    while true {
        let answer = prompt("\(message) \(hint)").lowercased()
        if answer.isEmpty { return defaultYes }
        if ["y", "yes"].contains(answer) { return true }
        if ["n", "no"].contains(answer) { return false }
        print("  Type y or n.")
    }
}

func audioDeviceName(_ id: AudioDeviceID) -> String {
    var address = addr(id, kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else {
        return "Audio device \(id)"
    }
    return name?.takeRetainedValue() as String? ?? "Audio device \(id)"
}

func transportName(_ id: AudioDeviceID) -> String {
    var address = addr(id, kAudioDevicePropertyTransportType)
    var transport = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
        return "unknown"
    }
    switch transport {
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    default: return String(format: "0x%08x", transport)
    }
}

func isOutput(_ id: AudioDeviceID) -> Bool {
    var address = addr(id, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
}

func allDevices() -> [AudioDeviceID] {
    var address = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices)
    return devices
}

func outputDevices() -> [AudioDeviceID] {
    allDevices().filter(isOutput)
}

func defaultOutput() -> AudioDeviceID? {
    var address = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
        return nil
    }
    return device
}

@discardableResult
func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
    var device = id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    let outputOK = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device) == noErr
    var system = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)
    let systemOK = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &system, 0, nil, size, &device) == noErr
    return outputOK && systemOK
}

func lockPresentationFormat(_ device: AudioDeviceID) -> String? {
    let transport = transportName(device)
    guard transport == "HDMI" || transport == "DisplayPort" else {
        return nil
    }
    var streamAddress = addr(device, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
    var streamSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else {
        return nil
    }
    var streams = [AudioStreamID](repeating: 0, count: Int(streamSize) / MemoryLayout<AudioStreamID>.stride)
    AudioObjectGetPropertyData(device, &streamAddress, 0, nil, &streamSize, &streams)
    guard let stream = streams.first else { return nil }

    var availAddress = addr(stream, kAudioStreamPropertyAvailablePhysicalFormats)
    var availSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(stream, &availAddress, 0, nil, &availSize) == noErr else {
        return nil
    }
    var items = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(availSize) / MemoryLayout<AudioStreamRangedDescription>.stride)
    AudioObjectGetPropertyData(stream, &availAddress, 0, nil, &availSize, &items)
    let preferred = items.first {
        $0.mFormat.mChannelsPerFrame == 2
            && $0.mFormat.mBitsPerChannel == 16
            && abs($0.mFormat.mSampleRate - 48000) < 1
    } ?? items.first {
        $0.mFormat.mChannelsPerFrame == 2
            && $0.mFormat.mBitsPerChannel == 16
            && abs($0.mFormat.mSampleRate - 44100) < 1
    }
    guard var format = preferred?.mFormat else { return nil }
    var formatAddress = addr(stream, kAudioStreamPropertyPhysicalFormat)
    let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectSetPropertyData(stream, &formatAddress, 0, nil, formatSize, &format) == noErr else {
        return nil
    }
    var rate = format.mSampleRate
    var rateAddress = addr(device, kAudioDevicePropertyNominalSampleRate)
    _ = AudioObjectSetPropertyData(device, &rateAddress, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
    return "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel)-bit"
}

func playDing() -> Int32 {
    let play = Process()
    play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    play.arguments = ["-t", "2", "/System/Library/Sounds/Glass.aiff"]
    do {
        try play.run()
        play.waitUntilExit()
        return play.terminationStatus
    } catch {
        fputs("afplay failed: \(error)\n", stderr)
        return 1
    }
}

func resetCoreAudio() -> Bool {
    print("\nmacOS will ask for your password to restart Core Audio.")
    let reset = Process()
    reset.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    reset.arguments = ["-e", "do shell script \"killall coreaudiod\" with administrator privileges"]
    do {
        try reset.run()
        reset.waitUntilExit()
    } catch {
        print("Could not start the password dialog: \(error)")
        return false
    }
    guard reset.terminationStatus == 0 else {
        print("Core Audio reset cancelled or failed.")
        return false
    }
    print("Core Audio restarted. Waiting 8 seconds for HDMI to re-enumerate…")
    Thread.sleep(forTimeInterval: 8)
    return true
}

func macSpeakers() -> AudioDeviceID? {
    outputDevices().first { audioDeviceName($0).contains("MacBook Pro Speakers") }
}

func relocateDevice(named name: String, transport: String) -> AudioDeviceID? {
    let outputs = outputDevices()
    return outputs.first { audioDeviceName($0) == name && transportName($0) == transport }
        ?? outputs.first { audioDeviceName($0) == name }
        ?? outputs.first { transportName($0) == "HDMI" }
}

func bounceThroughSpeakers(then device: AudioDeviceID) {
    if let speakers = macSpeakers() {
        print("Bouncing output via MacBook speakers so HDMI can re-bind…")
        _ = setDefaultOutput(speakers)
        Thread.sleep(forTimeInterval: 2)
    }
    _ = setDefaultOutput(device)
}

func displayIDs() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func screenName(for id: CGDirectDisplayID) -> String {
    for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            continue
        }
        if number.uint32Value == id {
            return screen.localizedName
        }
    }
    return CGDisplayIsBuiltin(id) != 0 ? "Built-in" : "External"
}

func modeSummary(_ mode: CGDisplayMode) -> String {
    let hz = mode.refreshRate
    let hzText = hz > 0 ? String(format: "%.0fHz", hz) : "default Hz"
    let scale = mode.pixelWidth > mode.width ? "HiDPI" : "1x"
    return "\(mode.width)x\(mode.height) \(hzText) \(scale)"
}

func isHiDPI(_ mode: CGDisplayMode) -> Bool {
    mode.pixelWidth > mode.width || mode.pixelHeight > mode.height
}

func isLowRefresh(_ mode: CGDisplayMode) -> Bool {
    mode.refreshRate > 0 && mode.refreshRate < 50
}

struct TargetMode {
    let width: Int
    let height: Int
    let refresh: Double
}

let preferredRoomModes = [
    TargetMode(width: 1920, height: 1080, refresh: 60),
    TargetMode(width: 3840, height: 2160, refresh: 60),
    TargetMode(width: 1920, height: 1080, refresh: 0),
    TargetMode(width: 1280, height: 720, refresh: 60),
]

func matches(_ mode: CGDisplayMode, _ target: TargetMode) -> Bool {
    guard mode.width == target.width, mode.height == target.height, !isHiDPI(mode) else {
        return false
    }
    if target.refresh <= 0 { return true }
    if mode.refreshRate <= 0 { return target.refresh == 60 }
    return abs(mode.refreshRate - target.refresh) < 1.5
}

func bestRoomMode(for display: CGDirectDisplayID) -> CGDisplayMode? {
    guard let modes = CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode] else {
        return nil
    }
    for target in preferredRoomModes {
        if let match = modes.first(where: { matches($0, target) }) {
            return match
        }
    }
    return nil
}

@discardableResult
func applySafeRoomModes() -> Bool {
    let ids = displayIDs()
    let builtin = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    let externals = ids.filter { CGDisplayIsBuiltin($0) == 0 }
    guard !externals.isEmpty else { return false }

    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
        print("Could not start a display change.")
        return false
    }
    for id in ids {
        _ = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
    }
    if let builtinMode = CGDisplayCopyDisplayMode(builtin) {
        _ = CGConfigureDisplayOrigin(config, builtin, 0, 0)
        var xOffset = Int32(builtinMode.width)
        for id in externals {
            guard let mode = bestRoomMode(for: id) else {
                CGCancelDisplayConfiguration(config)
                print("No 1080p60/4K60 1x mode on \(screenName(for: id)). Set it in System Settings → Displays.")
                return false
            }
            if CGConfigureDisplayWithDisplayMode(config, id, mode, nil) != .success {
                CGCancelDisplayConfiguration(config)
                print("Could not set \(screenName(for: id)) to \(modeSummary(mode)).")
                return false
            }
            _ = CGConfigureDisplayOrigin(config, id, xOffset, 0)
            print("Room display \(screenName(for: id)) → \(modeSummary(mode))")
            xOffset += Int32(mode.width)
        }
    }
    if CGCompleteDisplayConfiguration(config, .permanently) != .success {
        print("Display change failed. Unplug HDMI, wait 3 seconds, reconnect.")
        return false
    }
    Thread.sleep(forTimeInterval: 2)
    return true
}

func unmirrorDisplays() {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
        print("Could not start a display change.")
        return
    }
    for id in displayIDs() {
        if CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay) != .success {
            CGCancelDisplayConfiguration(config)
            print("Could not disable mirroring.")
            return
        }
    }
    if CGCompleteDisplayConfiguration(config, .permanently) != .success {
        print("Unmirror failed. Unplug HDMI, wait 3 seconds, reconnect, then run this again.")
        return
    }
    print("Mirroring is off. Laptop stays main. Room resolution was not changed.")
}

func roomScore(_ id: AudioDeviceID) -> Int {
    let name = audioDeviceName(id)
    let transport = transportName(id)
    if transport == "Virtual" { return 0 }
    if name.localizedCaseInsensitiveContains("MacBook") { return 1 }
    if transport == "Bluetooth" { return 2 }
    if transport == "USB" { return 6 }
    if transport == "DisplayPort" { return 8 }
    if transport == "HDMI" { return 9 }
    if name.localizedCaseInsensitiveContains("DELL")
        || name.localizedCaseInsensitiveContains("CS-")
        || name.localizedCaseInsensitiveContains("BOARD")
        || name.localizedCaseInsensitiveContains("Cisco")
        || name.localizedCaseInsensitiveContains("projector") {
        return 10
    }
    return 3
}

func pickOutputDevice() -> AudioDeviceID {
    let devices = outputDevices().sorted { lhs, rhs in
        if roomScore(lhs) != roomScore(rhs) {
            return roomScore(lhs) > roomScore(rhs)
        }
        return audioDeviceName(lhs) < audioDeviceName(rhs)
    }
    if devices.isEmpty {
        fail("No audio output devices found.")
    }
    let current = defaultOutput()
    let recommended = devices.first { roomScore($0) >= 6 } ?? current ?? devices[0]

    print("Audio outputs:")
    for (index, device) in devices.enumerated() {
        var mark = ""
        if device == current { mark += "  (current)" }
        if device == recommended { mark += "  ← recommended for the room" }
        print("  \(index + 1). \(audioDeviceName(device))  [\(transportName(device))]\(mark)")
    }
    print("")

    while true {
        let answer = prompt("Select output [1-\(devices.count)], or Enter for recommended:")
        if answer.isEmpty { return recommended }
        guard let number = Int(answer), (1...devices.count).contains(number) else {
            print("  Enter a number from 1 to \(devices.count).")
            continue
        }
        return devices[number - 1]
    }
}

func applyAndDing(_ device: AudioDeviceID) -> Int32 {
    if let format = lockPresentationFormat(device) {
        print("Locked \(audioDeviceName(device)) to \(format).")
    } else if ["HDMI", "DisplayPort"].contains(transportName(device)) {
        print("Could not lock 16-bit 48 kHz. Continuing with the current format.")
    }
    if setDefaultOutput(device) {
        print("Default output: \(audioDeviceName(device))")
    } else {
        print("Could not select that device. System Settings → Sound → \(audioDeviceName(device)).")
    }
    print("Waiting 3 seconds for the device…")
    Thread.sleep(forTimeInterval: 3)
    print("Playing ding…")
    let code = playDing()
    if code == 0 {
        print("macOS started the sound (afplay exit 0).")
    } else {
        print("macOS could not start HDMI/room audio (afplay exit \(code), AudioQueueStart failed).")
    }
    return code
}

print("Room presentation check")
print("Plug in the room cable first. Do not start YouTube or PowerPoint yet.\n")

let uptimeHours = ProcessInfo.processInfo.systemUptime / 3600
if uptimeHours >= 12 {
    print(String(format: "This Mac has been up %.0f hours. HDMI audio on this M4 Pro often dies after long uptime;", uptimeHours))
    print("Core Audio restart then fails, and only a reboot with the cable plugged in restores it.\n")
}

let ids = displayIDs()
let builtin = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
let externals = ids.filter { CGDisplayIsBuiltin($0) == 0 }

print("Displays:")
var mirrored = false
var unsafeRoomMode = false
for id in ids {
    let role = id == builtin ? "laptop" : "external"
    let isMirrored = CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
    if isMirrored { mirrored = true }
    let current = CGDisplayCopyDisplayMode(id)
    if id != builtin, let current, isHiDPI(current) || isLowRefresh(current) {
        unsafeRoomMode = true
    }
    let summary = current.map(modeSummary) ?? "unknown"
    print("  \(screenName(for: id)) [\(role)]  \(summary)\(isMirrored ? "  MIRRORED" : "")")
}
if externals.isEmpty {
    print("\nNo room screen yet. Plug in HDMI or USB-C, wait until it appears, then run this again.")
    exit(0)
}
if unsafeRoomMode {
    print("\nThe room screen is HiDPI and/or ~30 Hz (typical Cisco Board / TV EDID: 4K pixels as 1080p30).")
    print("That layout was present when HDMI I/O returned 'stop' on CS-BOARD55P-2.")
    if askYesNo("Switch the room screen to 1080p60 or 4K60 1x (not HiDPI) before testing sound?") {
        _ = applySafeRoomModes()
    }
} else if mirrored {
    if askYesNo("Room is mirrored. Turn mirroring off and keep the current resolution?") {
        unmirrorDisplays()
    }
} else {
    print("\nMirroring is off. Room mode looks like 1x ≥ 50 Hz.")
}

print("")
var device = pickOutputDevice()
let chosenName = audioDeviceName(device)
let chosenTransport = transportName(device)
print("")
var queueOK = applyAndDing(device) == 0
var heard = false

if queueOK {
    heard = askYesNo("Can you hear the ding in the room speakers?", defaultYes: true)
} else {
    print("You likely heard nothing in the room. macOS never started HDMI I/O ('stop' / 0 frames).")
    heard = false
}

if !heard {
    if unsafeRoomMode || askYesNo("Try 1080p60/4K60 1x, bounce HDMI, and restart Core Audio?", defaultYes: true) {
        if unsafeRoomMode {
            _ = applySafeRoomModes()
        }
        bounceThroughSpeakers(then: device)
        if resetCoreAudio() {
            if let found = relocateDevice(named: chosenName, transport: chosenTransport) {
                device = found
                print("Re-selected \(audioDeviceName(device)) (HAL id can change after a Core Audio restart).")
            } else {
                print("The previous device disappeared after the reset. Pick again.")
                device = pickOutputDevice()
            }
            queueOK = applyAndDing(device) == 0
            if queueOK {
                heard = askYesNo("Can you hear the ding in the room speakers now?", defaultYes: true)
            }
        }
    }
}

print("")
if heard {
    print("PASS: room speakers are live.")
    print("Leave this output selected. Play 10 seconds of YouTube or one PowerPoint clip.")
    print("If video freezes, press Esc and run this script again.")
    if askYesNo("Did that short video play with sound in the room?", defaultYes: true) {
        print("This room is good to present.")
    } else {
        print("Ding worked, video did not. Switch to MacBook speakers to recover, then reboot with the cable plugged in.")
        if let speakers = macSpeakers(), askYesNo("Switch sound to MacBook Pro Speakers now?", defaultYes: true) {
            _ = setDefaultOutput(speakers)
            print("Default output: \(audioDeviceName(speakers))")
        }
    }
} else {
    print("FAIL: HDMI/room audio I/O did not start. Format lock and Core Audio restart cannot unwedge this clock.")
    if uptimeHours >= 12 {
        print("This session has been up \(Int(uptimeHours)) hours. Reboot with the room cable already connected,")
        print("log in, then run this script before opening Chrome or PowerPoint.")
    } else {
        print("Reboot with the room cable already connected, log in, then run this script before any video.")
    }
    print("If HDMI still fails after that reboot: picture on HDMI, sound via USB into the codec or analog aux.")
    let usbRoom = outputDevices().filter { transportName($0) == "USB" && roomScore($0) >= 6 }
    if !usbRoom.isEmpty, askYesNo("Try USB room audio (\(audioDeviceName(usbRoom[0]))) instead of HDMI?", defaultYes: true) {
        _ = setDefaultOutput(usbRoom[0])
        print("Default output: \(audioDeviceName(usbRoom[0])). Play the ding from System Settings → Sound if you want a check.")
    } else if let speakers = macSpeakers(), askYesNo("Switch sound to MacBook Pro Speakers so the Mac does not freeze?", defaultYes: true) {
        _ = setDefaultOutput(speakers)
        print("Default output: \(audioDeviceName(speakers))")
    }
}
