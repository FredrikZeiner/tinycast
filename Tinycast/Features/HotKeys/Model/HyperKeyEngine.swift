import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct HyperKeyEngine: Sendable {
    enum Decision: Equatable, Sendable {
        case pass
        case suppress
        case rewrite(flags: UInt64, keyCode: Int64? = nil, asFlagsChanged: Bool = false)
    }

    struct Result: Equatable, Sendable {
        var decision: Decision
        var quickPress = false
        var switchInputSource = false
    }

    var route: HyperKeyRoute?
    var includesShift = true
    var quickPressAction: HyperKeyQuickPress = .none
    private(set) var isActive = false
    private var downAt: TimeInterval?
    private var used = false

    private enum DeviceFlags {
        static let leftControlOptionCommand: UInt64 = 0x29
        static let leftShift: UInt64 = 0x2
        static let bothShifts: UInt64 = 0x6
        static let rightControl: UInt64 = 0x2000
    }

    private var hyperFlags: UInt64 {
        var flags =
            CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue
            | DeviceFlags.leftControlOptionCommand
        if includesShift { flags |= CGEventFlags.maskShift.rawValue | DeviceFlags.leftShift }
        return flags
    }

    private func removingSourceFlags(from flags: UInt64) -> UInt64 {
        guard let route else { return flags }
        if route.key == .capsLock {
            let residue =
                CGEventFlags.maskAlphaShift.rawValue
                | (route.modifier == .rightControl ? DeviceFlags.rightControl : 0)
            return flags & ~residue
        }
        guard let own = route.key.ownFlag, hyperFlags & own.rawValue == 0 else { return flags }
        return flags & ~(own.rawValue | DeviceFlags.bothShifts)
    }

    @discardableResult
    mutating func reset() -> Bool {
        let wasActive = isActive
        isActive = false
        downAt = nil
        used = false
        return wasActive
    }

    mutating func handle(
        type: CGEventType, keyCode: Int, flags: UInt64, isAutorepeat: Bool = false,
        at time: TimeInterval, capsLockSwitchesInputSource: Bool = false
    ) -> Result {
        guard let route else { return Result(decision: .pass) }
        guard keyCode == route.tapKeyCode else {
            guard isActive else { return Result(decision: .pass) }
            if type == .keyDown || type == .flagsChanged { used = true }
            return Result(decision: .rewrite(flags: removingSourceFlags(from: flags) | hyperFlags))
        }

        let isDown: Bool
        let normalizedFlags: UInt64
        if let modifier = route.modifier {
            guard type == .flagsChanged else { return Result(decision: .pass) }
            isDown = modifier.isHeld(in: flags)
            normalizedFlags = removingSourceFlags(from: flags)
        } else {
            guard type == .keyDown || type == .keyUp else { return Result(decision: .pass) }
            guard !isAutorepeat else { return Result(decision: .suppress) }
            isDown = type == .keyDown
            normalizedFlags = removingSourceFlags(from: flags) & ~CGEventFlags.maskSecondaryFn.rawValue
        }

        if isDown {
            if !isActive {
                isActive = true
                downAt = time
                used = false
            }
            return Result(
                decision: .rewrite(
                    flags: normalizedFlags | hyperFlags, keyCode: Int64(kVK_Command), asFlagsChanged: true))
        }
        guard isActive else { return Result(decision: .suppress) }
        let duration = downAt.map { time - $0 } ?? 0
        let minimumCapsLockHold = capsLockSwitchesInputSource ? 0.15 : 0.075
        let quickPress =
            !used && route.key.hasOriginalFunction && quickPressAction != .none
            && (quickPressAction != .originalKey || route.key != .capsLock
                || duration >= minimumCapsLockHold)
        let switchInputSource =
            !used && route.key == .capsLock && quickPressAction == .originalKey
            && capsLockSwitchesInputSource && duration < minimumCapsLockHold
        reset()
        return Result(
            decision: .rewrite(flags: normalizedFlags, keyCode: Int64(kVK_Command), asFlagsChanged: true),
            quickPress: quickPress, switchInputSource: switchInputSource)
    }
}
