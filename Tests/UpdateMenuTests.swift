import Foundation
import Testing

@testable import OurWhisper

/// What the menu bar says about a waiting update — the glyph beside the clock and the item in the
/// menu. Both are pure functions of the app's state, so neither needs a menu to be opened.
@Suite("Update in the menu bar")
struct UpdateMenuTests {
    // MARK: - The glyph

    @Test("A waiting update replaces the idle glyph, and only the idle one")
    func updateReplacesOnlyTheIdleGlyph() {
        typealias State = AppState.RecordingState

        #expect(State.idle.menuBarGlyph(updateAvailable: false) == .asset(AppState.MenuBarGlyph.frog))
        #expect(State.idle.menuBarGlyph(updateAvailable: true) == .asset(AppState.MenuBarGlyph.frogWithUpdate))

        // Whatever the app is doing outranks an update that will still be there afterwards.
        for busy in [State.listening, .transcribing, .formatting, .answering, .failed("no")] {
            #expect(busy.menuBarGlyph(updateAvailable: true) == busy.menuBarGlyph(updateAvailable: false))
        }
    }

    @Test("The glyph is described to VoiceOver as an update")
    func updateIsAnnounced() {
        #expect(AppState.RecordingState.idle.accessibilityLabel(updateAvailable: true).contains("update"))
        #expect(!AppState.RecordingState.idle.accessibilityLabel(updateAvailable: false).contains("update"))
    }

    // MARK: - The item

    @Test("An installable update is one press away")
    func installableUpdateInstalls() {
        let row = UpdateMenuItem.row(release: release(), phase: .idle, refusal: nil, canStart: true)
        #expect(row.action == .install)
        #expect(row.title.contains("update"))
        #expect(row.subtitle.contains("9.9.9"))
    }

    @Test("A failed attempt can be tried again, and says that it failed")
    func failedAttemptRetries() {
        let row = UpdateMenuItem.row(release: release(), phase: .failed("boom"), refusal: nil, canStart: true)
        #expect(row.action == .install)
        #expect(row.subtitle.contains("failed"))
    }

    @Test("Nothing installs in the middle of a dictation")
    func noInstallMidDictation() {
        // Installing ends with the app quitting, and the sentence being spoken would go with it.
        let row = UpdateMenuItem.row(release: release(), phase: .idle, refusal: nil, canStart: false)
        #expect(row.action == nil)
    }

    @Test("A build that cannot update itself sends the user to the screen that says why")
    func refusalOpensHome() {
        let refused = UpdateMenuItem.row(release: release(), phase: .idle, refusal: "Ad-hoc signed.", canStart: true)
        #expect(refused.action == .openHome)

        // A release with no disk image is the same dead end for the same reason.
        let imageless = UpdateMenuItem.row(release: release(dmg: nil), phase: .idle, refusal: nil, canStart: true)
        #expect(imageless.action == .openHome)

        // Still told there is something newer.
        #expect(refused.title.contains("9.9.9"))
    }

    @Test("Nothing can be pressed while an update is under way", arguments: [
        UpdateInstaller.Phase.downloading(0.4),
        .downloading(nil),
        .verifying,
        .installing,
        .restarting,
    ])
    func busyRowsAreInert(phase: UpdateInstaller.Phase) {
        // A second press during the download would start a second one.
        let row = UpdateMenuItem.row(release: release(), phase: phase, refusal: nil, canStart: true)
        #expect(row.action == nil)
        #expect(!row.title.isEmpty && !row.subtitle.isEmpty)
    }

    @Test("The download shows its progress, or the version when it has none")
    func downloadProgress() {
        func subtitle(_ fraction: Double?) -> String {
            UpdateMenuItem.row(release: release(), phase: .downloading(fraction), refusal: nil, canStart: true).subtitle
        }
        #expect(subtitle(0.42) == "42%")
        // A fraction a hair over one is a rounding artefact, not 101%.
        #expect(subtitle(1.003) == "100%")
        #expect(subtitle(nil) == "Version 9.9.9")
    }

    @Test("An installed update waits for a quit rather than offering to install again")
    func installedWaitsForQuit() {
        let row = UpdateMenuItem.row(release: release(), phase: .installedNeedsRestart, refusal: nil, canStart: true)
        #expect(row.action == .quit)
    }

    private func release(dmg: UpdateChecker.Asset? = UpdateChecker.Asset(
        name: "OurWhisper-9.9.9-unnotarized.dmg",
        url: URL(string: "https://example.invalid/OurWhisper-9.9.9-unnotarized.dmg")!,
        size: 1
    )) -> UpdateChecker.Release {
        UpdateChecker.Release(
            version: "9.9.9",
            title: "Nine",
            notes: "",
            url: URL(string: "https://github.com/grozoww/our-whisper/releases/tag/v9.9.9")!,
            publishedAt: nil,
            dmg: dmg,
            checksums: dmg == nil ? nil : URL(string: "https://example.invalid/SHA256SUMS")!
        )
    }
}
