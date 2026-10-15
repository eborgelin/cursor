#!/bin/bash
# Apply 16-bit / 48 kHz on the HDMI sink, select it, play Glass.aiff.
# Exit 0 = beep started. Exit 1 = AudioQueueStart failed.
set -euo pipefail

swift - <<'SWIFT'
import CoreAudio
import Foundation

func addr(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func name(_ id: AudioObjectID) -> String {
  var a = addr(id, kAudioObjectPropertyName)
  var n: Unmanaged<CFString>?
  var s = UInt32(MemoryLayout<CFString?>.size)
  AudioObjectGetPropertyData(id, &a, 0, nil, &s, &n)
  return n?.takeRetainedValue() as String? ?? "?"
}
func transport(_ id: AudioDeviceID) -> UInt32 {
  var a = addr(id, kAudioDevicePropertyTransportType)
  var v = UInt32(0)
  var s = UInt32(MemoryLayout<UInt32>.size)
  AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v)
  return v
}
func devices() -> [AudioDeviceID] {
  var size: UInt32 = 0
  var a = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
  AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
  var list = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
  AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &list)
  return list
}
func setDefault(_ id: AudioDeviceID) {
  var d = id
  let sz = UInt32(MemoryLayout<AudioDeviceID>.size)
  var a = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
  AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, sz, &d)
  var b = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)
  AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &b, 0, nil, sz, &d)
}
func setFormat(device: AudioDeviceID, rate: Float64, bits: UInt32) -> String {
  var saddr = addr(device, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
  var ssize: UInt32 = 0
  AudioObjectGetPropertyDataSize(device, &saddr, 0, nil, &ssize)
  var streams = [AudioStreamID](repeating: 0, count: Int(ssize) / MemoryLayout<AudioStreamID>.stride)
  AudioObjectGetPropertyData(device, &saddr, 0, nil, &ssize, &streams)
  guard let stream = streams.first else { return "NO STREAM" }
  var availA = addr(stream, kAudioStreamPropertyAvailablePhysicalFormats)
  var availS: UInt32 = 0
  AudioObjectGetPropertyDataSize(stream, &availA, 0, nil, &availS)
  var items = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(availS) / MemoryLayout<AudioStreamRangedDescription>.stride)
  AudioObjectGetPropertyData(stream, &availA, 0, nil, &availS, &items)
  guard var fmt = items.first(where: { $0.mFormat.mBitsPerChannel == bits && abs($0.mFormat.mSampleRate-rate)<1 && $0.mFormat.mChannelsPerFrame==2 })?.mFormat else {
    return "FORMAT NOT FOUND"
  }
  var pa = addr(stream, kAudioStreamPropertyPhysicalFormat)
  var psz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  let ok = AudioObjectSetPropertyData(stream, &pa, 0, nil, psz, &fmt) == noErr
  var rateA = addr(device, kAudioDevicePropertyNominalSampleRate)
  var r = rate
  AudioObjectSetPropertyData(device, &rateA, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
  var now = AudioStreamBasicDescription()
  AudioObjectGetPropertyData(stream, &pa, 0, nil, &psz, &now)
  return "set=\(ok) now=\(Int(now.mSampleRate))Hz \(now.mBitsPerChannel)-bit"
}

let all = devices()
guard let hdmi = all.first(where: {
  let n = name($0)
  return n.localizedCaseInsensitiveContains("DELL")
    || n.localizedCaseInsensitiveContains("CS-")
    || n.localizedCaseInsensitiveContains("Cisco")
    || transport($0) == kAudioDeviceTransportTypeHDMI
}) else {
  fputs("FAIL: no HDMI / room audio device found.\n", stderr)
  exit(1)
}

print("Device: \(name(hdmi))")
print(setFormat(device: hdmi, rate: 48000, bits: 16))
setDefault(hdmi)
Thread.sleep(forTimeInterval: 2.0)

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
p.arguments = ["-t", "2", "/System/Library/Sounds/Glass.aiff"]
try p.run()
p.waitUntilExit()

if p.terminationStatus == 0 {
  print("PASS: HDMI audio queue started. You should have heard the monitor ding.")
  print("HDMI is still the default output. Play one short YouTube or PowerPoint clip next.")
  exit(0)
} else {
  fputs("FAIL: afplay exit \(p.terminationStatus). HDMI audio queue did not start.\n", stderr)
  print("HDMI remains selected. Reset Core Audio, or reboot with the cable plugged in.")
  exit(1)
}
SWIFT
