import AppKit
import CoreGraphics
import OSLog

/// Watches the keyboard system-wide for the dictation hotkey.
///
/// This is a `CGEventTap` rather than Carbon's `RegisterEventHotKey`. Carbon needs no permission,
/// which sounds attractive until you notice the app already requires Accessibility in order to
/// paste — so the permission is free — and that Carbon cannot express a modifier-only chord at
/// all, which is the default binding. One mechanism, no second code path.
///
/// The tap is fragile in two specific ways and both are handled below: macOS disables it if a
/// callback takes too long, and it dies silently when Accessibility is revoked.
@MainActor
final class HotkeyMonitor {
    enum Event: Sendable, Equatable {
        case toggle
        case pressStart
        case pressEnd
        case cancel
    }

    var onEvent: ((Event) -> Void)?

    /// Set while recording so Escape is swallowed instead of reaching the focused app.
    var isRecording = false

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "hotkey")

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Both are optional: in push-to-talk mode nothing is bound to toggle, and binding a chord
    /// that cannot be pressed would be a sentinel value waiting to be matched by accident.
    private var toggleChord: HotkeyChord?
    private var pushToTalkChord: HotkeyChord?

    /// How long a modifier-only push-to-talk chord must be held before it counts, and the timer
    /// counting it. See `DictationSettings.pushToTalkHoldDelay` for why the wait exists.
    private var pushToTalkHoldDelay: Duration = .zero

    /// Readable so a test can wait on the timer itself. Waiting a fixed time instead failed on a
    /// loaded CI runner, where the timer fired after the assertion had already looked. Take the
    /// task *before* the release that cancels it: cancelling clears this property, and awaiting the
    /// cancelled task is how a test proves the press never started.
    private(set) var pendingPressStart: Task<Void, Never>?

    /// Whether the modifier-only chord was already fully held on the previous event. Without this
    /// every extra `flagsChanged` while the chord is held would re-fire the hotkey.
    private var toggleChordEngaged = false
    private var pushToTalkEngaged = false

    private(set) var isArmed = false

    // MARK: - Lifecycle

    func configure(toggle: HotkeyChord?, pushToTalk: HotkeyChord?, holdDelay: Duration = .zero) {
        toggleChord = toggle
        pushToTalkChord = pushToTalk
        pushToTalkHoldDelay = holdDelay
        // A rebind mid-hold would otherwise fire a press for a chord that is no longer bound.
        cancelPendingPressStart()
    }

    /// Installs the tap. Returns false when Accessibility is missing, which is the only common
    /// cause of failure and the one the UI needs to explain.
    @discardableResult
    func arm() -> Bool {
        guard !isArmed else { return true }
        guard AXIsProcessTrusted() else {
            log.warning("Cannot arm hotkey: Accessibility permission not granted")
            return false
        }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // A default tap can swallow the hotkey so it never reaches the focused app. A
            // listen-only tap cannot, which would type a stray character on every dictation.
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: context
        ) else {
            log.error("CGEvent.tapCreate returned nil")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isArmed = true
        log.info("Hotkey tap armed")
        return true
    }

    func disarm() {
        guard let tap, let runLoopSource else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.runLoopSource = nil
        isArmed = false
        toggleChordEngaged = false
        pushToTalkEngaged = false
        cancelPendingPressStart()
    }

    // MARK: - Event handling

    /// Called on the run loop that owns the tap — the main run loop — so main-actor state is
    /// safe to touch. It must return fast: slow callbacks are exactly what makes macOS disable
    /// the tap.
    ///
    /// `CGEvent` is not `Sendable`, so the plain values are pulled out here and only those cross
    /// into the isolated closure. The event itself never does.
    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        let decision = MainActor.assumeIsolated {
            self.decide(type: type, keyCode: keyCode, flags: flags)
        }
        return decision == .consume ? nil : Unmanaged.passUnretained(event)
    }

    enum Decision {
        case pass
        case consume
    }

    /// Internal rather than private so the hold-delay timing can be driven from a test: arming a
    /// real tap needs Accessibility, which the test suite deliberately does not have.
    func decide(type: CGEventType, keyCode: CGKeyCode, flags: CGEventFlags) -> Decision {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switched us off. Re-enabling is the documented recovery, and without it the
            // hotkey silently stops working until the app is restarted.
            log.warning("Tap disabled by system; re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return .pass

        case .flagsChanged:
            return handleFlagsChanged(flags)

        case .keyDown:
            return handleKeyDown(keyCode: keyCode, flags: flags)

        case .keyUp:
            return handleKeyUp(keyCode: keyCode)

        default:
            return .pass
        }
    }

    private func handleFlagsChanged(_ flags: CGEventFlags) -> Decision {
        if let chord = pushToTalkChord, chord.isModifierOnly {
            let satisfied = chord.isSatisfied(by: flags)
            if satisfied, !pushToTalkEngaged, pendingPressStart == nil {
                beginPressStart()
            } else if !satisfied {
                // Released before the hold delay elapsed: the tap belonged to whatever else the
                // key means — switching input source, on fn — and we never started at all.
                cancelPendingPressStart()
                if pushToTalkEngaged {
                    pushToTalkEngaged = false
                    onEvent?(.pressEnd)
                }
            }
        }

        if let toggleChord, toggleChord.isModifierOnly {
            let satisfied = toggleChord.isSatisfied(by: flags)
            // Rising edge only. A modifier chord emits one flagsChanged per key, so holding
            // ⌥⌘⌃⇧ produces four events and only the last one completes the chord.
            if satisfied, !toggleChordEngaged {
                toggleChordEngaged = true
                onEvent?(.toggle)
            } else if !satisfied {
                toggleChordEngaged = false
            }
        }

        // Modifier events are never swallowed: consuming them would strip the modifier from
        // whatever the user does next.
        return .pass
    }

    private func handleKeyDown(keyCode: CGKeyCode, flags: CGEventFlags) -> Decision {
        let escape: CGKeyCode = 53

        if isRecording, keyCode == escape, flags.intersection(HotkeyChord.significantFlags).isEmpty {
            onEvent?(.cancel)
            return .consume // so Escape does not also dismiss something in the focused app
        }

        if let toggleChord, let code = toggleChord.keyCode, code == keyCode,
           toggleChord.isSatisfied(by: flags) {
            onEvent?(.toggle)
            return .consume
        }

        if let chord = pushToTalkChord, let code = chord.keyCode, code == keyCode,
           chord.isSatisfied(by: flags), !pushToTalkEngaged {
            pushToTalkEngaged = true
            onEvent?(.pressStart)
            return .consume
        }

        return .pass
    }

    /// Fires the press now, or arms the timer that will. The timer is a `Task` rather than work
    /// inside the tap callback on purpose: a slow callback is what makes macOS disable the tap.
    private func beginPressStart() {
        guard pushToTalkHoldDelay > .zero else {
            pushToTalkEngaged = true
            onEvent?(.pressStart)
            return
        }
        let delay = pushToTalkHoldDelay
        pendingPressStart = Task { [weak self] in
            try? await Task.sleep(for: delay)
            // `Task.sleep` throws on cancellation and `try?` swallows it, so the check has to be
            // explicit or a released key would still start a recording.
            guard !Task.isCancelled, let self else { return }
            self.pendingPressStart = nil
            self.pushToTalkEngaged = true
            self.onEvent?(.pressStart)
        }
    }

    private func cancelPendingPressStart() {
        pendingPressStart?.cancel()
        pendingPressStart = nil
    }

    private func handleKeyUp(keyCode: CGKeyCode) -> Decision {
        if let chord = pushToTalkChord, let code = chord.keyCode, code == keyCode, pushToTalkEngaged {
            pushToTalkEngaged = false
            onEvent?(.pressEnd)
            return .consume
        }
        return .pass
    }
}
