import Carbon.HIToolbox
import CoreGraphics
import Foundation

@main
@MainActor
struct HyperKeyEngineTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool) {
        if !condition { failures += 1; print("FAIL \(name)") }
    }

    static func main() {
        for key in HyperKeyPhysicalKey.allCases where key != .none {
            for includesShift in [false, true] {
                for compatible in [false, true] {
                    guard let route = key.route(secureInputCompatible: compatible) else { continue }
                    var engine = HyperKeyEngine(
                        route: route, includesShift: includesShift, quickPressAction: .escape)
                    let context = "\(key) shift=\(includesShift) compatible=\(compatible)"
                    let downFlags: UInt64 =
                        route.modifier.map { modifier in
                            [UInt64(1), 2, 4, 8, 16, 32, 64, 8192].first { modifier.isHeld(in: $0) }!
                        } ?? CGEventFlags.maskSecondaryFn.rawValue
                    let type: CGEventType = route.modifier == nil ? .keyDown : .flagsChanged
                    let down = engine.handle(type: type, keyCode: route.tapKeyCode, flags: downFlags, at: 0)
                    if case .rewrite(let flags, let code, let changed) = down.decision {
                        let expected =
                            CGEventFlags([.maskCommand, .maskControl, .maskAlternate]).rawValue
                            | (includesShift ? CGEventFlags.maskShift.rawValue : 0)
                        check("\(context) emits the chord", flags & 0x1F0000 == expected)
                        check("\(context) uses Command transitions", code == Int64(kVK_Command) && changed)
                        check("\(context) strips Caps/Fn residue", flags & 0x810000 == 0)
                        if key == .capsLock && compatible {
                            check("\(context) strips Right Control device residue", flags & 0x2000 == 0)
                        }
                    } else {
                        check("\(context) down rewrites", false)
                    }
                    let chord = engine.handle(type: .keyDown, keyCode: kVK_ANSI_G, flags: 0, at: 0.05)
                    if case .rewrite(let flags, _, _) = chord.decision {
                        check(
                            "\(context) applies modifiers to keys",
                            flags & CGEventFlags.maskCommand.rawValue != 0)
                    } else {
                        check("\(context) combo rewrites", false)
                    }
                    let upType: CGEventType = route.modifier == nil ? .keyUp : .flagsChanged
                    let up = engine.handle(type: upType, keyCode: route.tapKeyCode, flags: 0, at: 0.1)
                    check("\(context) combo has no quick action", !up.quickPress)
                    check(
                        "\(context) releases modifiers",
                        up.decision
                            == .rewrite(
                                flags: 0, keyCode: Int64(kVK_Command), asFlagsChanged: true))
                    check("\(context) release resets hold", !engine.isActive)
                    check(
                        "\(context) ordinary typing passes",
                        engine.handle(
                            type: .keyDown, keyCode: kVK_ANSI_G, flags: 0, at: 0.2
                        ).decision == .pass)
                }
            }
        }
        quickPress()
        interruption()
        print("Hyper Key engine: \(failures) failures")
        if failures != 0 { exit(1) }
    }

    static func quickPress() {
        let route = HyperKeyPhysicalKey.capsLock.route(secureInputCompatible: false)!
        for action in HyperKeyQuickPress.allCases {
            for duration in [0.01, 0.074, 0.076, 0.149, 0.151, 0.8] {
                for switchesInput in [false, true] {
                    var engine = HyperKeyEngine(route: route, quickPressAction: action)
                    _ = engine.handle(type: .keyDown, keyCode: route.tapKeyCode, flags: 0, at: 0)
                    let up = engine.handle(
                        type: .keyUp, keyCode: route.tapKeyCode, flags: 0,
                        at: duration, capsLockSwitchesInputSource: switchesInput)
                    let expected =
                        action == .escape
                        || (action == .originalKey
                            && duration >= (switchesInput ? 0.15 : 0.075))
                    check(
                        "quick action \(action) at \(duration), IME=\(switchesInput)",
                        up.quickPress == expected)
                    let switches = action == .originalKey && switchesInput && duration < 0.15
                    check("short Caps Lock press switches input source", up.switchInputSource == switches)
                }
            }
        }
        var engine = HyperKeyEngine(route: route, quickPressAction: .escape)
        _ = engine.handle(type: .keyDown, keyCode: route.tapKeyCode, flags: 0, at: 0)
        check(
            "autorepeat is suppressed",
            engine.handle(
                type: .keyDown, keyCode: route.tapKeyCode,
                flags: 0, isAutorepeat: true, at: 0.5
            ).decision == .suppress)
        check(
            "autorepeat never re-arms the action",
            engine.handle(
                type: .keyUp,
                keyCode: route.tapKeyCode, flags: 0, at: 1
            ).quickPress)
    }

    static func interruption() {
        let route = HyperKeyPhysicalKey.capsLock.route(secureInputCompatible: true)!
        var engine = HyperKeyEngine(route: route, quickPressAction: .escape)
        _ = engine.handle(type: .flagsChanged, keyCode: route.tapKeyCode, flags: 0x2000, at: 0)
        check("interruption knows a release is needed", engine.reset())
        check("repeated reset emits no extra release", !engine.reset())
        let droppedUp = engine.handle(type: .flagsChanged, keyCode: route.tapKeyCode, flags: 0, at: 0.1)
        check("a release after cancellation does not replay an action", !droppedUp.quickPress)
        check("a release after cancellation cannot invert the hold", !engine.isActive)
        _ = engine.handle(type: .flagsChanged, keyCode: route.tapKeyCode, flags: 0x2000, at: 1)
        check("the next press recovers", engine.isActive)
    }
}
