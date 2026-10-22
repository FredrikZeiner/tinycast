import AppKit

/// Lends 🎤 to Tinycast as F20. See docs/features/hotkeys.md#the-dictation-key.
@MainActor
final class DictationKeyManager {
    var onProblem: ((String) -> Void)?

    private let hotKeys: HotKeyManager
    private let remapper = KeyboardRemapper(
        directory: AppPaths.shared(), name: "dictation-key", owner: Bundle.main.appDisplayName)
    private var sessionTokens: [NotificationToken] = []
    private var isSessionActive = true

    init(hotKeys: HotKeyManager) {
        self.hotKeys = hotKeys
    }

    func start() {
        observeHotKeys()
        observeSession()
        apply()
    }

    func prepareForTermination() {
        remapper.restore()
    }

    private func apply() {
        let isWanted = hotKeys.recordingAction != nil || hotKeys.bindsDictationKey
        guard isWanted, isSessionActive else {
            remapper.restore()
            return
        }
        let isChange = remapper.mapping != .dictationKeyToF20
        if remapper.apply(.dictationKeyToF20) == .unavailable, isChange, hotKeys.bindsDictationKey {
            onProblem?(String(localized: "macOS refused to remap the Dictation key"))
        }
    }

    /// onChange fires before the write lands.
    private func observeHotKeys() {
        withObservationTracking {
            _ = hotKeys.recordingAction
            _ = hotKeys.bindsDictationKey
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeHotKeys()
                self.apply()
            }
        }
    }

    /// HID mappings are system-wide.
    private func observeSession() {
        let center = NSWorkspace.shared.notificationCenter
        let transitions = [
            (NSWorkspace.sessionDidResignActiveNotification, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, true)
        ]
        sessionTokens = transitions.map { name, isActive in
            NotificationToken(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.isSessionActive = isActive
                        self.apply()
                    }
                }, center: center)
        }
    }
}
