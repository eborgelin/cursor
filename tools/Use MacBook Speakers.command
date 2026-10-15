#!/bin/bash
# Double-click: send sound back to the laptop. Picture on HDMI stays.
set +e
swift - <<'SWIFT'
import CoreAudio
import Foundation
func addr(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func name(_ id: AudioObjectID) -> String {
  var a = addr(id, kAudioObjectPropertyName)
  var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<CFString?>.size)
  AudioObjectGetPropertyData(id, &a, 0, nil, &s, &n)
  return n?.takeRetainedValue() as String? ?? "?"
}
var size: UInt32 = 0
var a = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
var list = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &list)
guard let spk = list.first(where: { name($0).contains("MacBook Pro Speakers") }) else {
  fputs("MacBook Pro Speakers not found.\n", stderr)
  exit(1)
}
var d = spk
let sz = UInt32(MemoryLayout<AudioDeviceID>.size)
var out = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &out, 0, nil, sz, &d)
var sys = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)
AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sys, 0, nil, sz, &d)
print("Default output: \(name(spk))")
SWIFT
echo
read -r -n 1 -s -p "Press any key to close..."
echo
