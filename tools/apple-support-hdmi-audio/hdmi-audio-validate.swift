import CoreAudio
import Foundation

/// Sets the HDMI/display audio device to a presentation-safe format
/// (2ch, 16-bit, 48 kHz), optionally makes it the default output, and
/// plays a one-second system sound through it.
///
/// Usage:
///   hdmi-audio-validate              # apply 16/48, beep, restore previous output
///   hdmi-audio-validate --stay       # leave HDMI as the default output
///   hdmi-audio-validate --rate 44100 # try 16-bit 44.1 kHz instead

struct Options {
    var stay = false
    var rate: Float64 = 48000
    var bits: UInt32 = 16
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--stay":
            options.stay = true
        case "--rate":
            if let value = args.next(), let rate = Float64(value) {
                options.rate = rate
            }
        case "--bits":
            if let value = args.next(), let bits = UInt32(value) {
                options.bits = bits
            }
        case "-h", "--help":
            print("hdmi-audio-validate [--stay] [--rate 48000|44100|32000] [--bits 16|20|24]")
            exit(0)
        default:
            fputs("Unknown argument: \(arg)\n", stderr)
            exit(2)
        }
    }
    return options
}

func addr(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func deviceName(_ id: AudioObjectID) -> String {
    var address = addr(id, kAudioObjectPropertyName)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
    return name?.takeRetainedValue() as String? ?? "device \(id)"
}

func transport(_ id: AudioDeviceID) -> UInt32 {
    var address = addr(id, kAudioDevicePropertyTransportType)
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
    return value
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

func defaultOutput() -> AudioDeviceID? {
    var address = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
        return nil
    }
    return device
}

func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
    var address = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    var device = id
    let size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device) == noErr else {
        return false
    }
    var system = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &system, 0, nil, size, &device) == noErr
}

func outputStream(_ device: AudioDeviceID) -> AudioStreamID? {
    var address = addr(device, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
        return nil
    }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.stride)
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams)
    return streams.first
}

func currentPhysical(_ stream: AudioStreamID) -> AudioStreamBasicDescription? {
    var address = addr(stream, kAudioStreamPropertyPhysicalFormat)
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd) == noErr else {
        return nil
    }
    return asbd
}

func availablePhysical(_ stream: AudioStreamID) -> [AudioStreamRangedDescription] {
    var address = addr(stream, kAudioStreamPropertyAvailablePhysicalFormats)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr else {
        return []
    }
    var items = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.stride)
    AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &items)
    return items
}

func formatLabel(_ asbd: AudioStreamBasicDescription) -> String {
    "\(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, \(asbd.mBitsPerChannel)-bit"
}

func findHDMIDevice() -> AudioDeviceID? {
    let hdmi = allDevices().filter { isOutput($0) && transport($0) == kAudioDeviceTransportTypeHDMI }
    if let dell = hdmi.first(where: { deviceName($0).localizedCaseInsensitiveContains("DELL") }) {
        return dell
    }
    if let cisco = hdmi.first(where: { deviceName($0).localizedCaseInsensitiveContains("CS-") || deviceName($0).localizedCaseInsensitiveContains("Cisco") }) {
        return cisco
    }
    return hdmi.first
}

func setPhysicalFormat(stream: AudioStreamID, rate: Float64, bits: UInt32) -> AudioStreamBasicDescription? {
    let match = availablePhysical(stream).first { item in
        item.mFormat.mChannelsPerFrame == 2
            && item.mFormat.mBitsPerChannel == bits
            && abs(item.mFormat.mSampleRate - rate) < 1
    }
    guard var format = match?.mFormat else {
        return nil
    }
    var address = addr(stream, kAudioStreamPropertyPhysicalFormat)
    let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectSetPropertyData(stream, &address, 0, nil, size, &format) == noErr else {
        return nil
    }
    return currentPhysical(stream)
}

func setDeviceRate(_ device: AudioDeviceID, _ rate: Float64) {
    var address = addr(device, kAudioDevicePropertyNominalSampleRate)
    var value = rate
    let size = UInt32(MemoryLayout<Float64>.size)
    _ = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
}

let options = parseOptions()
print("HDMI audio validate")

guard let hdmi = findHDMIDevice() else {
    fputs("No HDMI audio device is connected.\n", stderr)
    exit(1)
}
guard let stream = outputStream(hdmi) else {
    fputs("HDMI device has no output stream.\n", stderr)
    exit(1)
}

print("Device: \(deviceName(hdmi))")
if let current = currentPhysical(stream) {
    print("Before: \(formatLabel(current))")
}

setDeviceRate(hdmi, options.rate)
guard let applied = setPhysicalFormat(stream: stream, rate: options.rate, bits: options.bits) else {
    fputs("Could not set \(Int(options.rate)) Hz / \(options.bits)-bit / 2 ch. Available:\n", stderr)
    for item in availablePhysical(stream) {
        fputs("  \(formatLabel(item.mFormat))\n", stderr)
    }
    exit(1)
}
print("After:  \(formatLabel(applied))")

let previous = defaultOutput()
if !setDefaultOutput(hdmi) {
    fputs("Could not select HDMI as the default output.\n", stderr)
    exit(1)
}
print("Default output: \(deviceName(hdmi))")

let sound = "/System/Library/Sounds/Glass.aiff"
print("Playing \(sound) over HDMI…")
let play = Process()
play.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
play.arguments = ["-t", "2", sound]
do {
    try play.run()
    play.waitUntilExit()
} catch {
    fputs("afplay failed: \(error)\n", stderr)
    exit(1)
}

if play.terminationStatus == 0 {
    print("Audio-only playback succeeded (afplay exit 0).")
    print("You should have heard a ding from the monitor speakers.")
} else {
    fputs("afplay exited \(play.terminationStatus). HDMI audio did not play.\n", stderr)
}

if options.stay {
    print("HDMI remains the default output. Play one YouTube or PowerPoint clip now.")
} else if let previous, previous != hdmi {
    _ = setDefaultOutput(previous)
    print("Restored previous output: \(deviceName(previous))")
    print("Re-run with --stay before a video test so HDMI stays selected.")
}
