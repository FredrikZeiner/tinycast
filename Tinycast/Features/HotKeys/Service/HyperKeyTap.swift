import AppKit
import Carbon.HIToolbox
@preconcurrency import IOKit.hidsystem

// Snapshot the mutable C global `mach_task_self_`, so actor code never reads it raw.
private let machTaskSelf = mach_task_self_

@MainActor
final class HyperKeyTap {
    typealias Decision = HyperKeyEngine.Decision

    /// Marker on events this tap posts, so it never reacts to its own synthetics.
    nonisolated static let syntheticTag: Int64 = 0x5459_4354

    var route: HyperKeyRoute? {
        didSet {
            guard route != oldValue || engine.includesShift != settings.hyperKeyIncludesShift else { return }
            cancelHold()
            engine.route = route
            engine.includesShift = settings.hyperKeyIncludesShift
        }
    }

    var onUnmappedCapsLock: (() -> Void)?

    private let settings: AppSettings
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hidConnect: io_connect_t = IO_OBJECT_NULL

    private var engine = HyperKeyEngine()
    private var quickPressTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
    }

    // Isolated so teardown can release the main-actor IOKit connection.
    isolated deinit {
        tearDown()
        if hidConnect != IO_OBJECT_NULL { IOServiceClose(hidConnect) }
    }

    var isInstalled: Bool { tapPort != nil }
    var isEnabled: Bool? { tapPort.map { CGEvent.tapIsEnabled(tap: $0) } }
    var runLoopSourceIsValid: Bool? { runLoopSource.map(CFRunLoopSourceIsValid) }

    func decide(
        type: CGEventType, keyCode: Int, flagsRaw: UInt64, isAutorepeat: Bool, isSynthetic: Bool
    ) -> Decision {
        guard !isSynthetic, let route else { return .pass }
        if route.key == .capsLock, keyCode == kVK_CapsLock, type == .flagsChanged {
            Task { @MainActor [weak self] in self?.onUnmappedCapsLock?() }
            return .pass
        }
        return process(type: type, keyCode: keyCode, flags: flagsRaw, isAutorepeat: isAutorepeat)
    }

    private func process(
        type: CGEventType, keyCode: Int, flags: UInt64, isAutorepeat: Bool
    ) -> Decision {
        if keyCode == route?.tapKeyCode, type == .keyDown {
            quickPressTask?.cancel()
            quickPressTask = nil
        }
        engine.includesShift = settings.hyperKeyIncludesShift
        engine.quickPressAction = settings.hyperKeyQuickPress
        let switchesInputSource =
            route?.key == .capsLock && type != .keyDown
            && settings.hyperKeyQuickPress == .originalKey
            && UserDefaults.standard.bool(forKey: "TISRomanSwitchState")
        let result = engine.handle(
            type: type, keyCode: keyCode, flags: flags, isAutorepeat: isAutorepeat,
            at: ProcessInfo.processInfo.systemUptime,
            capsLockSwitchesInputSource: switchesInputSource)
        if result.quickPress || result.switchInputSource, let key = route?.key {
            let action = settings.hyperKeyQuickPress
            quickPressTask?.cancel()
            quickPressTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled, let self, self.route?.key == key,
                    self.settings.hyperKeyQuickPress == action
                else { return }
                self.quickPressTask = nil
                if result.switchInputSource {
                    if !IsSecureEventInputEnabled() { InputSourceSwitcher.toggleCapsLockInputSource() }
                } else {
                    self.fireQuickPress(action)
                }
            }
        }
        return result.decision
    }

    private func fireQuickPress(_ action: HyperKeyQuickPress) {
        // Secure Input hides the key that made this press a chord, so a short hold proves nothing.
        guard !IsSecureEventInputEnabled() else { return }
        switch action {
        case .none:
            break
        case .originalKey:
            setCapsLockState(!capsLockState())
        case .escape:
            postKey(CGKeyCode(kVK_Escape))
        }
    }

    func cancelHold() {
        quickPressTask?.cancel()
        quickPressTask = nil
        guard engine.reset() else { return }
        postModifierRelease()
    }

    // MARK: - Tap lifecycle

    @discardableResult
    func install() -> Bool {
        guard tapPort == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: { @MainActor _, type, event, userInfo in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let tap = Unmanaged<HyperKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        tap.reenable()
                        return Unmanaged.passUnretained(event)
                    }
                    let decision = tap.decide(
                        type: type,
                        keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                        flagsRaw: event.flags.rawValue,
                        isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                        isSynthetic: event.getIntegerValueField(.eventSourceUserData)
                            == HyperKeyTap.syntheticTag)
                    switch decision {
                    case .pass: return Unmanaged.passUnretained(event)
                    case .suppress: return nil
                    case .rewrite(let flags, let keyCode, let asFlagsChanged):
                        if asFlagsChanged { event.type = .flagsChanged }
                        if let keyCode { event.setIntegerValueField(.keyboardEventKeycode, value: keyCode) }
                        event.flags = CGEventFlags(rawValue: flags)
                        return Unmanaged.passUnretained(event)
                    }
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tapPort = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    func tearDown() {
        cancelHold()
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: false)
            CFMachPortInvalidate(tapPort)
            self.tapPort = nil
        }
    }

    /// Called when the system disables the tap; any half-tracked hold is stale by then.
    func reenable() {
        cancelHold()
        if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
    }

    // MARK: - Synthetics & caps state

    private func postModifierRelease() {
        guard let event = CGEvent(source: nil) else { return }
        event.type = .flagsChanged
        event.flags = []
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_Command))
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        event.post(tap: .cghidEventTap)
    }

    /// Synthesize a bare key press for Quick Press, tagged so `decide` ignores it.
    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        for event in [down, up] {
            // The session source still carries our injected chord, and a modified Escape is eaten.
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Remapping takes Caps Lock's own function away, so a latched lock would stay stuck on.
    func unlatchCapsLock() {
        setCapsLockState(false)
    }

    /// The IOHIDSystem connection for the Caps Lock LED and lock state.
    private func hidConnection() -> io_connect_t {
        if hidConnect != IO_OBJECT_NULL { return hidConnect }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != IO_OBJECT_NULL else { return IO_OBJECT_NULL }
        var connect: io_connect_t = IO_OBJECT_NULL
        IOServiceOpen(service, machTaskSelf, UInt32(kIOHIDParamConnectType), &connect)
        IOObjectRelease(service)
        hidConnect = connect
        return connect
    }

    private func capsLockState() -> Bool {
        let connect = hidConnection()
        guard connect != IO_OBJECT_NULL else { return false }
        var on = false
        IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &on)
        return on
    }

    private func setCapsLockState(_ on: Bool) {
        let connect = hidConnection()
        guard connect != IO_OBJECT_NULL else { return }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }
}
