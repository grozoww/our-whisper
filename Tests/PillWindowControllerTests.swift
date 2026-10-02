import AppKit
import Testing

@testable import OurWhisper

/// The pill being up when a dictation is.
///
/// The other way it went missing — the window server keeping a hidden window on one desktop —
/// needs a private API to set up, so it is not here; `PillWindowController.panelOnThisDesktop`
/// records what was measured.
///
/// These wait on the dismissal timer itself rather than for a fixed time. A timer set for 20 ms
/// took up to 465 ms to fire while other suites were using the main thread, so any fixed wait is
/// either flaky or proves nothing.
@MainActor
@Suite("The pill stays up", .serialized)
struct PillWindowControllerTests {
    private func isVisible(_ pill: PillWindowController) throws -> Bool {
        let number = try #require(pill.windowNumber)
        return try #require(NSApp.window(withWindowNumber: number)).isVisible
    }

    @Test("A new dictation is not hidden by the last one's dismissal")
    func showOutlivesAPendingDismissal() async throws {
        let pill = PillWindowController()
        pill.show()
        let pending = pill.dismiss(after: .milliseconds(20))
        // The next dictation starts before the last one's pill has gone.
        pill.show()
        await pending.value

        #expect(try isVisible(pill))
        pill.hide()
    }

    @Test("A dismissal still dismisses")
    func dismissalHides() async throws {
        let pill = PillWindowController()
        pill.show()
        await pill.dismiss(after: .milliseconds(20)).value

        #expect(try isVisible(pill) == false)
    }
}
