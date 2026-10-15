import AppKit
import CoreAudio
import CoreGraphics
import Foundation

/// Menu-bar status for the HDMI display clock. Idle until an external display
/// and an HDMI audio device are both present, then one silent StartIO test.
/// The icon is hidden unless that clock is dead.

private let showMenuNotification = Notification.Name("com.eborgeli.AppleHDMIMenu.showMenu")
private let hideDefaultsKey = "hideIconWhenNoIssue"
private let restartTooltip = "Restart the Mac with the HDMI cable plugged in to reinitialize HDMI audio."
private let bundleIdentifier = "com.eborgeli.AppleHDMIMenu"

private enum ClockState {
    case absent
    case ok
    case dead
}

private func addr(
    _ id: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func silenceIOProc(
    _ inDevice: AudioObjectID,
    _ inNow: UnsafePointer<AudioTimeStamp>,
    _ inInputData: UnsafePointer<AudioBufferList>,
    _ inInputTime: UnsafePointer<AudioTimeStamp>,
    _ outOutputData: UnsafeMutablePointer<AudioBufferList>,
    _ inOutputTime: UnsafePointer<AudioTimeStamp>,
    _ inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    let buffers = UnsafeMutableAudioBufferListPointer(outOutputData)
    for buffer in buffers {
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
        memset(data, 0, Int(buffer.mDataByteSize))
    }
    return noErr
}

private func displayReconfigured(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    if flags.contains(.beginConfigurationFlag) { return }
    let addedExternal = flags.contains(.addFlag) && CGDisplayIsBuiltin(display) == 0
    DispatchQueue.main.async {
        AppDelegate.shared?.noteDisplay(addedExternal: addedExternal)
    }
}

private enum HDMIClockProbe {
    static func isAlive(_ device: AudioDeviceID) -> Bool {
        if isRunningSomewhere(device) {
            return sampleTimeAdvances(device, timeout: 1.0)
        }
        return startSilentIO(device)
    }

    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var address = addr(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    private static func currentSampleTime(_ device: AudioDeviceID) -> Float64? {
        var stamp = AudioTimeStamp()
        guard AudioDeviceGetCurrentTime(device, &stamp) == noErr else { return nil }
        guard stamp.mFlags.contains(.sampleTimeValid) else { return nil }
        return stamp.mSampleTime
    }

    private static func sampleTimeAdvances(_ device: AudioDeviceID, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previous = currentSampleTime(device)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            guard let now = currentSampleTime(device) else { continue }
            if let previous, now > previous { return true }
            previous = now
        }
        return false
    }

    /// Starts IO on this device only. Does not change the system default output.
    private static func startSilentIO(_ device: AudioDeviceID) -> Bool {
        var procID: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(device, silenceIOProc, nil, &procID) == noErr, let procID else {
            return false
        }
        defer {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
        }
        guard AudioDeviceStart(device, procID) == noErr else { return false }
        return sampleTimeAdvances(device, timeout: 1.0)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem!
    private var optionsMenu: NSMenu!
    private var hideItem: NSMenuItem!
    private var menuObserver: NSObjectProtocol?
    private let probeQueue = DispatchQueue(label: "com.eborgeli.AppleHDMIMenu.probe", qos: .userInitiated)
    private let idleImage = AppDelegate.hdmiImage(markedDead: false)
    private let deadImage = AppDelegate.hdmiImage(markedDead: true)

    private var suppressIdle = true
    private var menuForcedVisible = false
    private var isOpeningMenu = false
    private var menuOpened = false
    private var clock: ClockState = .absent
    private var probeInFlight = false
    private var probeAgain = false
    private var flushScheduled = false
    private var externalDisplayAdded = false
    private var lastHDMIUIDs = Set<String>()
    private var lastDefaultUID = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        if relinquishToExistingInstance() { return }

        UserDefaults.standard.register(defaults: [hideDefaultsKey: true])
        suppressIdle = UserDefaults.standard.bool(forKey: hideDefaultsKey)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.behavior = []
        statusItem.isVisible = false
        if let button = statusItem.button {
            button.image = idleImage
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        optionsMenu = NSMenu()
        optionsMenu.autoenablesItems = false
        optionsMenu.delegate = self
        hideItem = NSMenuItem(
            title: "Hide icon when there is no HDMI or no issue",
            action: #selector(toggleHide(_:)),
            keyEquivalent: ""
        )
        hideItem.target = self
        hideItem.state = suppressIdle ? .on : .off
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        optionsMenu.addItem(hideItem)
        optionsMenu.addItem(quitItem)

        menuObserver = DistributedNotificationCenter.default().addObserver(
            forName: showMenuNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.presentOptionsMenu()
        }

        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        addAudioListener(kAudioHardwarePropertyDevices)
        addAudioListener(kAudioHardwarePropertyDefaultOutputDevice)
        scheduleFlush()
    }

    func applicationWillTerminate(_ notification: Notification) {
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, nil)
        if let menuObserver {
            DistributedNotificationCenter.default().removeObserver(menuObserver)
        }
    }

    func noteDisplay(addedExternal: Bool) {
        if addedExternal { externalDisplayAdded = true }
        scheduleFlush()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpened = true
        hideItem.state = suppressIdle ? .on : .off
    }

    func menuDidClose(_ menu: NSMenu) {
        menuForcedVisible = false
        applyAppearance()
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard !isOpeningMenu else { return }
        isOpeningMenu = true
        menuOpened = false
        menuForcedVisible = true
        applyAppearance()
        statusItem.menu = optionsMenu
        sender.performClick(nil)
        statusItem.menu = nil
        isOpeningMenu = false
        if !menuOpened {
            menuForcedVisible = false
            applyAppearance()
        }
    }

    @objc private func toggleHide(_ sender: NSMenuItem) {
        suppressIdle.toggle()
        UserDefaults.standard.set(suppressIdle, forKey: hideDefaultsKey)
        sender.state = suppressIdle ? .on : .off
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func relinquishToExistingInstance() -> Bool {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        guard !others.isEmpty else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            showMenuNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        NSApp.terminate(nil)
        return true
    }

    private func presentOptionsMenu() {
        menuForcedVisible = true
        applyAppearance()
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.statusClicked(button)
        }
    }

    private func addAudioListener(_ selector: AudioObjectPropertySelector) {
        var address = addr(AudioObjectID(kAudioObjectSystemObject), selector)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        if flushScheduled { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushProbe()
        }
    }

    private func flushProbe() {
        if probeInFlight {
            probeAgain = true
            return
        }

        let displays = Self.externalDisplayIDs()
        let hdmi = Self.hdmiOutputDevices()
        let uids = Set(hdmi.map(Self.deviceUID))
        let defaultUID = Self.defaultOutputDevice().map(Self.deviceUID) ?? ""
        let added = externalDisplayAdded
        let uidsChanged = uids != lastHDMIUIDs
        let defaultChanged = defaultUID != lastDefaultUID
        externalDisplayAdded = false
        lastHDMIUIDs = uids
        lastDefaultUID = defaultUID

        guard !displays.isEmpty, let device = Self.probeTarget(among: hdmi) else {
            clock = .absent
            applyAppearance()
            return
        }

        let shouldProbe = added || uidsChanged || (defaultChanged && uids.contains(defaultUID))
        guard shouldProbe else {
            applyAppearance()
            return
        }
        beginProbe(device)
    }

    private func beginProbe(_ device: AudioDeviceID) {
        probeInFlight = true
        let expectedUID = Self.deviceUID(device)
        probeQueue.async { [weak self] in
            let current = Self.device(withUID: expectedUID)
            let alive = current.map(HDMIClockProbe.isAlive) ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeInFlight = false
                let stillConnected = !Self.externalDisplayIDs().isEmpty
                    && Self.hdmiOutputDevices().contains { Self.deviceUID($0) == expectedUID }
                if stillConnected {
                    self.clock = alive ? .ok : .dead
                } else {
                    self.clock = .absent
                }
                self.applyAppearance()
                if self.probeAgain {
                    self.probeAgain = false
                    self.flushProbe()
                }
            }
        }
    }

    private func applyAppearance() {
        let show = clock == .dead || menuForcedVisible || !suppressIdle
        statusItem.isVisible = show
        guard let button = statusItem.button else { return }
        if clock == .dead {
            button.image = deadImage
            button.image?.isTemplate = false
            button.contentTintColor = nil
            button.toolTip = restartTooltip
        } else {
            button.image = idleImage
            button.image?.isTemplate = true
            button.contentTintColor = nil
            button.toolTip = nil
        }
    }

    /// Menu-bar glyphs from the system symbol set so they match the current menu bar.
    /// Idle uses a template connector (light and dark). A dead clock uses the slashed
    /// connector in system red, the same "unavailable" language as Wi-Fi.
    private static func hdmiImage(markedDead: Bool) -> NSImage {
        let name = markedDead ? "cable.connector.slash" : "cable.connector"
        let description = markedDead ? "HDMI audio clock is dead" : "HDMI"
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold, scale: .medium)
        if markedDead {
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemRed))
        }
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        let image = symbol ?? NSImage(systemSymbolName: "cable.connector", accessibilityDescription: description) ?? NSImage()
        image.isTemplate = !markedDead
        return image
    }

    private static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices
    }

    private static func isOutput(_ id: AudioDeviceID) -> Bool {
        var address = addr(id, kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = addr(id, kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
            return 0
        }
        return transport
    }

    private static func hdmiOutputDevices() -> [AudioDeviceID] {
        allDeviceIDs().filter { isOutput($0) && transportType($0) == kAudioDeviceTransportTypeHDMI }
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = addr(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else {
            return nil
        }
        return device
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String {
        var address = addr(id, kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr else {
            return "id:\(id)"
        }
        return (uid?.takeRetainedValue() as String?) ?? "id:\(id)"
    }

    private static func device(withUID uid: String) -> AudioDeviceID? {
        hdmiOutputDevices().first { deviceUID($0) == uid }
    }

    private static func probeTarget(among hdmi: [AudioDeviceID]) -> AudioDeviceID? {
        if let current = defaultOutputDevice(), hdmi.contains(current) { return current }
        return hdmi.first
    }
}

private let appDelegate = AppDelegate()
AppDelegate.shared = appDelegate
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = appDelegate
application.run()
