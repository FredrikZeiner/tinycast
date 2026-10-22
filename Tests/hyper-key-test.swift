import Foundation

@main
@MainActor
struct HyperKeyTest {
    static var failures = 0

    static func main() {
        keyMappingReconcile()
        keyMappingConflicts()
        keyMappingParsing()
        knownApps()
        modifierKeysPreferences()
        karabinerConfig()
        remapperLifecycle()
        print(failures == 0 ? "All hyper key checks passed" : "\(failures) hyper key check(s) failed")
        if failures > 0 { exit(1) }
    }

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static let toF18 = HIDKeyMapping.capsLockToF18
    static let toRightControl = HIDKeyMapping.capsLockToRightControl
    static let toF20 = HIDKeyMapping.dictationKeyToF20
    static let otherTool = HIDKeyMapping(source: 0x7_0000_0029, destination: 0x7_0000_0035)

    static func keyMappingReconcile() {
        let otherCapsLock = HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: 0x7_0000_0029)
        check("placing on an empty keyboard adds just ours", toF18.replacingSource(in: []) == [toF18])
        check(
            "placing keeps another tool's entry for a different key",
            toF18.replacingSource(in: [otherTool]) == [otherTool, toF18])
        check(
            "placing replaces another entry for the same key",
            toF18.replacingSource(in: [otherCapsLock, otherTool]) == [otherTool, toF18])
        check(
            "switching routes swaps one Hyper entry for the other",
            toRightControl.replacingSource(in: [toF18, otherTool]) == [otherTool, toRightControl])
        check(
            "an entry already in place is left as it is",
            toF18.replacingSource(in: [otherTool, toF18]) == [otherTool, toF18])
        check(
            "restoring removes only the mapping still owned",
            toF18.restoring([], in: [otherTool, toF18]) == [otherTool])
        check(
            "restoring leaves another tool's replacement alone",
            toF18.restoring([], in: [otherCapsLock]) == [otherCapsLock])
    }

    static func keyMappingConflicts() {
        check("the same key sent elsewhere is a conflict", toF18.conflicts(with: [toRightControl]))
        check("our own mapping already in place is not a conflict", !toF18.conflicts(with: [toF18]))
        check("a mapping for another key is not a conflict", !toF18.conflicts(with: [otherTool]))
    }

    static func keyMappingParsing() {
        let raw: [Any] = [
            [
                HIDKeyMapping.sourceKey: NSNumber(value: HIDKeyMapping.capsLock),
                HIDKeyMapping.destinationKey: NSNumber(value: HIDKeyMapping.f18)
            ],
            [HIDKeyMapping.sourceKey: Int(0x7_0000_0029), HIDKeyMapping.destinationKey: Int(0x7_0000_0035)],
            [HIDKeyMapping.sourceKey: NSNumber(value: HIDKeyMapping.capsLock)],
            "not a mapping"
        ]
        check(
            "a UserKeyMapping array reads numbers and integers, skipping malformed entries",
            HIDKeyMapping.mappings(from: raw) == [toF18, otherTool])
        check("a missing UserKeyMapping reads as no mappings", HIDKeyMapping.mappings(from: nil).isEmpty)
        check(
            "a mapping survives a round trip through its dictionary",
            HIDKeyMapping(dictionary: toRightControl.dictionary) == toRightControl)
    }

    static func knownApps() {
        check(
            "Hyperkey and Superkey block the Hyper Key",
            HyperKeyConflictPolicy.severity(ofBundleID: "com.knollsoft.Hyperkey") == .blocking
                && HyperKeyConflictPolicy.severity(ofBundleID: "com.knollsoft.Superkey") == .blocking)
        check(
            "BetterTouchTool is only a warning",
            HyperKeyConflictPolicy.severity(ofBundleID: "com.hegenberg.BetterTouchTool") == .warning)
        check(
            "an unknown app is no conflict",
            HyperKeyConflictPolicy.severity(ofBundleID: "com.apple.Safari") == nil)
        check(
            "Karabiner's virtual keyboard is recognised by name",
            HyperKeyConflictPolicy.isKarabinerVirtualKeyboard(
                named: "Karabiner DriverKit VirtualHIDKeyboard 1.8.0")
                && !HyperKeyConflictPolicy.isKarabinerVirtualKeyboard(named: "Apple Internal Keyboard"))
        check(
            "1Password is a likely Secure Input holder",
            HyperKeyConflictPolicy.secureInputSuspects.contains("com.1password.1password"))
    }

    static func modifierKeysPreferences() {
        let prefix = HyperKeyConflictPolicy.modifierMappingPrefix
        let preferences: [String: Any] = [
            prefix + "1452-834-0": [toRightControl.dictionary],
            prefix + "1133-49948-0": [
                HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: HIDKeyMapping.capsLock).dictionary
            ],
            prefix + "0-0-0": [toF18.dictionary],
            prefix + "1234-5-0": [otherTool.dictionary],
            "AppleKeyboardUIMode": 2
        ]
        let remaps = HyperKeyConflictPolicy.capsLockRemaps(in: preferences)
        check(
            "keyboards whose Caps Lock is moved are reported, sorted",
            remaps == [.init(vendorID: 0, productID: 0), .init(vendorID: 1452, productID: 834)])
        check("the 0-0-0 entry reads as the default keyboard", remaps.first?.isDefault == true)
        check(
            "no preferences means no Caps Lock conflicts",
            HyperKeyConflictPolicy.capsLockRemaps(in: [:]).isEmpty)
    }

    @MainActor
    struct RemapLab {
        let directory: URL
        var journal: URL { journal(named: "hyper-key") }
        var hasJournal: Bool { hasJournal(named: "hyper-key") }

        func journal(named name: String) -> URL { directory.appending(path: "\(name).json") }

        func hasJournal(named name: String) -> Bool {
            FileManager.default.fileExists(atPath: journal(named: name).path(percentEncoded: false))
        }

        func remapper(_ owner: String = "Tinycast", name: String = "hyper-key") -> KeyboardRemapper {
            KeyboardRemapper(directory: directory, name: name, owner: owner)
        }
    }

    static func remapperLifecycle() {
        func fixture(_ body: (RemapLab) -> Void) {
            HIDEventSystem.reset()
            let directory = FileManager.default.temporaryDirectory
                .appending(path: "tinycast.hyper-key-test.\(UUID())")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            body(RemapLab(directory: directory))
        }
        fixture { lab in
            let remapper = lab.remapper()
            HIDEventSystem.mappings[1] = [otherTool]
            check("enable succeeds", remapper.apply(toF18) == .applied)
            check("enable preserves unrelated mappings", HIDEventSystem.mappings[1] == [otherTool, toF18])
            check("enable journals recovery", lab.hasJournal)
            let writes = HIDEventSystem.writeCount
            check(
                "idempotent apply avoids writes",
                remapper.apply(toF18) == .applied && HIDEventSystem.writeCount == writes)
            HIDEventSystem.connect(2)
            check("hot plug remaps new keyboards", HIDEventSystem.mappings[2] == [toF18])
            HIDEventSystem.mappings[2] = []
            check(
                "repair restores a lost mapping", remapper.repair() && HIDEventSystem.mappings[2] == [toF18])
            check("repair avoids writes when correct", !remapper.repair())
            check("route switching succeeds", remapper.apply(toRightControl) == .applied)
            check(
                "route switching reaches both keyboards",
                HIDEventSystem.mappings.values.allSatisfy {
                    $0.contains(toRightControl) && !$0.contains(toF18)
                })
            check("cleanup succeeds", remapper.restore())
            check(
                "cleanup preserves unrelated mappings",
                HIDEventSystem.mappings[1] == [otherTool] && HIDEventSystem.mappings[2] == [])
            check("completed cleanup removes recovery", !lab.hasJournal)
        }
        fixture { lab in
            let remapper = lab.remapper()
            HIDEventSystem.rejectedKeyboards = [1]
            check("rejected writes report failure", remapper.apply(toF18) == .unavailable)
            HIDEventSystem.rejectedKeyboards = []
            check("the same route retries after failure", remapper.apply(toF18) == .applied)
        }
        fixture { lab in
            let remapper = lab.remapper()
            HIDEventSystem.connect(2)
            HIDEventSystem.rejectedKeyboards = [2]
            check("a keyboard that rejects the remap is skipped", remapper.apply(toF18) == .applied)
            check(
                "only accepted writes change keyboards",
                HIDEventSystem.mappings[1] == [toF18] && HIDEventSystem.mappings[2] == nil)
            check(
                "partial success can be cleaned up", remapper.restore() && HIDEventSystem.mappings[1] == [])
            check("partial cleanup removes recovery", !lab.hasJournal)
        }
        fixture { lab in
            let remapper = lab.remapper()
            _ = remapper.apply(toF18)
            HIDEventSystem.rejectedKeyboards = [1]
            check("rejected cleanup reports failure", !remapper.restore())
            check("rejected cleanup keeps recovery", lab.hasJournal)
            HIDEventSystem.rejectedKeyboards = []
            lab.remapper().restore()
            check("relaunch retries rejected cleanup", HIDEventSystem.mappings[1] == [])
            check("relaunch clears successful recovery", !lab.hasJournal)
        }
        fixture { lab in
            let remapper = lab.remapper()
            let original = HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: 0x7_0000_0029)
            HIDEventSystem.mappings[1] = [original, otherTool]
            _ = remapper.apply(toF18)
            _ = remapper.apply(toRightControl)
            check(
                "disable restores displaced Caps Lock mapping",
                remapper.restore() && Set(HIDEventSystem.mappings[1] ?? []) == [original, otherTool])
            do { _ = lab.remapper().apply(toF18) }
            lab.remapper().restore()
            check(
                "crash recovery restores displaced mapping",
                Set(HIDEventSystem.mappings[1] ?? []) == [original, otherTool])
        }
        fixture { lab in
            let remapper = lab.remapper()
            HIDEventSystem.mappings[1] = [toF18, otherTool]
            _ = remapper.apply(toF18)
            remapper.restore()
            check(
                "an identical pre-existing mapping is never owned",
                HIDEventSystem.mappings[1] == [toF18, otherTool])
            _ = remapper.apply(toRightControl)
            remapper.restore()
            check(
                "another tool's Hyper mapping is restored",
                Set(HIDEventSystem.mappings[1] ?? []) == [toF18, otherTool])
        }
        fixture { lab in
            let remapper = lab.remapper()
            _ = remapper.apply(toF18)
            let replacement = HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: 0x7_0000_0029)
            HIDEventSystem.mappings[1] = [replacement, otherTool]
            remapper.restore()
            check(
                "cleanup preserves another tool's later replacement",
                HIDEventSystem.mappings[1] == [replacement, otherTool])
        }
        fixture { lab in
            var journal: Data?
            do {
                let crashing = lab.remapper()
                _ = crashing.apply(toF18)
                HIDEventSystem.beforeWrite = { journal = try? Data(contentsOf: lab.journal) }
                _ = crashing.apply(toRightControl)
                HIDEventSystem.beforeWrite = nil
            }
            for installed in [toF18, toRightControl] {
                try? journal?.write(to: lab.journal)
                HIDEventSystem.mappings[1] = [installed, otherTool]
                lab.remapper().restore()
                check(
                    "route-change crash recovers \(installed.destination)",
                    HIDEventSystem.mappings[1] == [otherTool])
            }
        }
        fixture { lab in
            let remapper = lab.remapper()
            _ = remapper.apply(toF18)
            HIDEventSystem.devices = []
            check(
                "disconnected keyboard keeps recovery pending", !remapper.restore() && lab.hasJournal)
            HIDEventSystem.connect(1)
            check(
                "reconnection completes deferred cleanup",
                HIDEventSystem.mappings[1] == [] && !lab.hasJournal)
        }
        fixture { lab in
            do { _ = lab.remapper().apply(toF18) }
            guard let data = try? Data(contentsOf: lab.journal),
                var recovery = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                check("recovery journal decodes", false)
                return
            }
            recovery["bootSessionID"] = "previous-boot"
            guard let previousBoot = try? JSONSerialization.data(withJSONObject: recovery) else {
                check("previous-boot journal encodes", false)
                return
            }
            try? previousBoot.write(to: lab.journal)
            lab.remapper().restore()
            check(
                "recovery from another boot cannot claim a reused registry ID",
                HIDEventSystem.mappings[1] == [toF18])
        }
        fixture { lab in
            HIDEventSystem.available = false
            check("missing HID SPI reports failure", lab.remapper().apply(toF18) == .unavailable)
        }
        fixture { lab in
            let remapper = lab.remapper()
            HIDEventSystem.devices = []
            check("no keyboard yet still succeeds", remapper.apply(toF18) == .applied)
            HIDEventSystem.connect(1)
            check("the first keyboard to connect gets the remap", HIDEventSystem.mappings[1] == [toF18])
        }
        fixture { lab in
            let remapper = lab.remapper()
            _ = remapper.apply(toF18)
            HIDEventSystem.rejectedKeyboards = [2]
            HIDEventSystem.connect(2)
            check(
                "a rejected hot-plug write leaves the other keyboards remapped",
                remapper.mapping == toF18 && HIDEventSystem.mappings[1] == [toF18]
                    && HIDEventSystem.mappings[2] == nil)
        }
        fixture { lab in
            let remapper = lab.remapper()
            let dictation = lab.remapper(name: "dictation-key")
            HIDEventSystem.mappings[1] = [otherTool]
            _ = remapper.apply(toF18)
            _ = dictation.apply(toF20)
            check(
                "Caps Lock and 🎤 remaps share a keyboard",
                HIDEventSystem.mappings[1] == [otherTool, toF18, toF20])
            check(
                "each remapper keeps its own recovery journal",
                lab.hasJournal && lab.hasJournal(named: "dictation-key"))
            dictation.restore()
            check("removing 🎤 keeps Caps Lock", HIDEventSystem.mappings[1] == [otherTool, toF18])
            _ = dictation.apply(toF20)
            remapper.restore()
            check("removing Caps Lock keeps 🎤", HIDEventSystem.mappings[1] == [otherTool, toF20])
        }
        fixture { lab in
            let stable = lab.remapper("Tinycast")
            let dev = lab.remapper("Tinycast Dev")
            check("the first channel to remap holds the keyboards", stable.apply(toF18) == .applied)
            check(
                "a second channel learns who holds them", dev.apply(toRightControl) == .held(by: "Tinycast"))
            check("a refused channel writes nothing", HIDEventSystem.mappings[1] == [toF18])
            check(
                "a channel without the lease leaves a live remap alone",
                !dev.restore() && HIDEventSystem.mappings[1] == [toF18])
            stable.restore()
            check("a waiting channel takes over once released", dev.apply(toRightControl) == .applied)
            dev.restore()
            check(
                "channels taking turns leave Caps Lock unmapped",
                HIDEventSystem.mappings[1] == [] && !lab.hasJournal)
        }
        fixture { lab in
            do { _ = lab.remapper("Tinycast Dev").apply(toRightControl) }
            let stable = lab.remapper("Tinycast")
            check("a crashed channel's lease lapses", stable.apply(toF18) == .applied)
            stable.restore()
            check(
                "a channel cleans up another's crashed remap",
                HIDEventSystem.mappings[1] == [] && !lab.hasJournal)
        }
    }

    static func karabinerConfig() {
        func config(_ profiles: [[String: Any]]) -> Data {
            (try? JSONSerialization.data(withJSONObject: ["profiles": profiles])) ?? Data()
        }
        let simple: [String: Any] = [
            "selected": true,
            "simple_modifications": [["from": ["key_code": "caps_lock"], "to": [["key_code": "escape"]]]]
        ]
        let complex: [String: Any] = [
            "selected": true,
            "complex_modifications": [
                "rules": [["manipulators": [["from": ["key_code": "right_command"], "type": "basic"]]]]
            ]
        ]
        let perDevice: [String: Any] = [
            "selected": true,
            "devices": [["simple_modifications": [["from": ["key_code": "left_option"]]]]]
        ]
        let unselected: [String: Any] = [
            "selected": false,
            "simple_modifications": [["from": ["key_code": "caps_lock"]]]
        ]
        check(
            "a simple modification of the key is a conflict",
            HyperKeyConflictPolicy.karabinerRemaps("capsLock", config: config([simple])))
        check(
            "a complex modification of the key is a conflict",
            HyperKeyConflictPolicy.karabinerRemaps("rightCommand", config: config([complex])))
        check(
            "a per-device modification of the key is a conflict",
            HyperKeyConflictPolicy.karabinerRemaps("leftOption", config: config([perDevice])))
        check(
            "a profile that is not selected does not count",
            !HyperKeyConflictPolicy.karabinerRemaps("capsLock", config: config([unselected, complex])))
        check(
            "a modification of another key is not a conflict",
            !HyperKeyConflictPolicy.karabinerRemaps("rightShift", config: config([simple])))
        check(
            "an unreadable config is not a conflict",
            !HyperKeyConflictPolicy.karabinerRemaps("capsLock", config: Data("{".utf8)))
    }
}
