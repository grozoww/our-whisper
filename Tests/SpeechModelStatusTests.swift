import AppKit
import FluidAudio
import Foundation
import Testing

@testable import OurWhisper

/// What the speech model says about itself, and what each screen and the hotkey do with it.
///
/// This is the bug a user reported as "it showed 50%, froze, I restarted, it said installed, and
/// still would not work for a while". It was three places each describing one preparation
/// differently, so what is held still here is the one description they now all read.
@Suite("Speech model status")
@MainActor
struct SpeechModelStatusTests {
    /// Waits for something the status does on another turn of the run loop: progress hops to the
    /// main actor one update at a time.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: - The hotkey

    @Test("The hotkey records only when the model is ready, and says why when it is not", arguments: [
        (SpeechModelStatus.State.ready, SpeechModelStatus.Gate.proceed),
        (.starting, .wait("Speech model is still loading")),
        (.downloading(0.38), .wait("Speech model is downloading — 38%")),
        (.optimizing, .wait("Speech model is optimizing for this Mac")),
        (.notLoaded, .loadFirst("Speech model is not loaded — loading it")),
        (.failed("offline"), .loadFirst("Speech model is not loaded — loading it")),
    ])
    func gate(state: SpeechModelStatus.State, expected: SpeechModelStatus.Gate) {
        #expect(SpeechModelStatus.gate(for: state, usesSpeechModel: true) == expected)
    }

    @Test("A dictation that does not use the speech model is never held up by it", arguments: [
        SpeechModelStatus.State.notLoaded, .starting, .downloading(0.1), .optimizing, .failed("x"), .ready,
    ])
    func cloudDictationIgnoresTheLocalModel(state: SpeechModelStatus.State) {
        #expect(SpeechModelStatus.gate(for: state, usesSpeechModel: false) == .proceed)
    }

    @Test("Every pill message fits on the pill's one line")
    func messagesFit() {
        // `PillView` draws a failure on one line, 320 points wide with a warning triangle in front,
        // and truncates the rest — so the longer sentence Home can afford would arrive as half a
        // sentence. Measured with the pill's own font rather than counted in characters.
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let room: CGFloat = 320 - 16 - 7 - 7   // the pill, the triangle, the gap, and some air

        for state in [SpeechModelStatus.State.starting, .downloading(1), .optimizing, .notLoaded] {
            switch SpeechModelStatus.gate(for: state, usesSpeechModel: true) {
            case .wait(let message), .loadFirst(let message):
                let width = (message as NSString).size(withAttributes: [.font: font]).width
                #expect(width <= room, "\(message) is \(Int(width)) points wide; the pill has \(Int(room))")
            case .proceed:
                Issue.record("\(state) let a dictation through")
            }
        }
    }

    // MARK: - The state machine

    @Test("A preparation reports the wait it is in, then is ready")
    func followsTheWork() async throws {
        let status = SpeechModelStatus()
        let (finish, release) = AsyncStream<Void>.makeStream()

        let task = Task {
            try await status.prepare { report in
                report(.downloading(fraction: 0.4))
                for await _ in finish { break }
            }
        }

        #expect(await eventually { status.state == .downloading(0.4) })
        #expect(status.state.isBusy)
        #expect(status.startedAt != nil)

        release.yield()
        try await task.value
        #expect(status.state == .ready)
        #expect(!status.state.isBusy)
    }

    @Test("A compile is reported as optimizing, with no number to freeze at")
    func optimizing() async throws {
        let status = SpeechModelStatus()
        let (finish, release) = AsyncStream<Void>.makeStream()

        let task = Task {
            try await status.prepare { report in
                report(.downloading(fraction: 1))
                report(.optimizing)
                for await _ in finish { break }
            }
        }

        #expect(await eventually { status.state == .optimizing })
        release.yield()
        try await task.value
    }

    @Test("Callers who arrive while it runs share the one preparation")
    func joinsTheRunningWork() async throws {
        // The launch path, the Models button and the hotkey can all ask at once. Two preparations
        // would be two downloads of the same files.
        let status = SpeechModelStatus()
        let (finish, release) = AsyncStream<Void>.makeStream()
        let counter = Counter()

        let first = Task {
            try await status.prepare { _ in
                counter.increment()
                for await _ in finish { break }
            }
        }
        #expect(await eventually { status.state == .starting })

        let second = Task {
            try await status.prepare { _ in counter.increment() }
        }
        try? await Task.sleep(for: .milliseconds(50))

        release.yield()
        try await first.value
        try await second.value

        #expect(counter.value == 1)
        #expect(status.state == .ready)
    }

    @Test("A failure is the state, the error is rethrown, and the next attempt tries again")
    func failsAndRetries() async throws {
        struct Offline: LocalizedError { var errorDescription: String? { "The Internet connection appears to be offline." } }
        let status = SpeechModelStatus()
        let counter = Counter()

        await #expect(throws: Offline.self) {
            try await status.prepare { _ in counter.increment(); throw Offline() }
        }
        #expect(status.state == .failed("The Internet connection appears to be offline."))

        // Not stuck: a failure is not remembered as "already tried".
        try await status.prepare { _ in counter.increment() }
        #expect(counter.value == 2)
        #expect(status.state == .ready)
    }

    @Test("A late progress report cannot turn ready back into optimizing")
    func lateUpdatesAreDropped() async throws {
        // Updates arrive on FluidAudio's queue and are hopped across one at a time, so the last of
        // them can land after the preparation has finished.
        let status = SpeechModelStatus()
        try await status.prepare { _ in }
        #expect(status.state == .ready)

        status.apply(.optimizing)
        status.apply(.downloading(fraction: 0.5))
        #expect(status.state == .ready)
    }

    @Test("Something that is not being prepared ignores progress altogether")
    func idleIgnoresProgress() {
        let status = SpeechModelStatus()
        status.apply(.optimizing)
        #expect(status.state == .notLoaded)
    }

    @Test("Resetting forgets a ready model, and leaves one that is being prepared alone")
    func resets() async throws {
        let status = SpeechModelStatus()
        try await status.prepare { _ in }
        status.reset()
        #expect(status.state == .notLoaded)
        #expect(status.startedAt == nil)

        let (finish, release) = AsyncStream<Void>.makeStream()
        let task = Task { try await status.prepare { _ in for await _ in finish { break } } }
        #expect(await eventually { status.state == .starting })
        status.reset()
        #expect(status.state == .starting)
        release.yield()
        try await task.value
    }

    @Test("Whoever is listening is told when a preparation ends, either way")
    func announcesTheEnd() async throws {
        struct Failure: Error {}
        let status = SpeechModelStatus()
        let counter = Counter()
        status.onFinish = { counter.increment() }

        try await status.prepare { _ in }
        status.reset()
        _ = try? await status.prepare { _ in throw Failure() }

        #expect(counter.value == 2)
    }

    // MARK: - What FluidAudio's one number means

    @Test("The download is the first half of FluidAudio's bar, and the compile is the second")
    func readsFluidAudiosBar() {
        func progress(_ fraction: Double, _ phase: DownloadPhase) -> SpeechModelProgress? {
            ParakeetProvider.progress(from: DownloadProgress(fractionCompleted: fraction, phase: phase))
        }

        // Asking the server what there is: nothing to show.
        #expect(progress(0, .listing) == nil)

        // A quarter of the way through the files is half of the download's half of the bar.
        #expect(progress(0.25, .downloading(completedFiles: 1, totalFiles: 4)) == .downloading(fraction: 0.5))
        #expect(progress(0.5, .downloading(completedFiles: 4, totalFiles: 4)) == .downloading(fraction: 1))

        // Out of range in either direction is clamped rather than drawn off the end of the bar.
        #expect(progress(0.9, .downloading(completedFiles: 1, totalFiles: 1)) == .downloading(fraction: 1))
        #expect(progress(-0.1, .downloading(completedFiles: 1, totalFiles: 1)) == .downloading(fraction: 0))

        // The cache was complete, so there was no download — FluidAudio says "finished" for files it
        // never fetched, on its way to the compile, and that must not flash a full bar.
        #expect(progress(0.5, .downloading(completedFiles: 0, totalFiles: 0)) == nil)

        // The compile has no number worth showing, whatever FluidAudio puts in the fraction.
        #expect(progress(0.5, .compiling(modelName: "Encoder.mlmodelc")) == .optimizing)
        #expect(progress(0.875, .compiling(modelName: "JointDecisionv3.mlmodelc")) == .optimizing)
        #expect(progress(1, .compiling(modelName: "")) == .optimizing)
    }
}

/// A counter two tasks can touch, for asserting how many times work ran.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// What the Home row says, in words — asserted, because the words were the bug.
@Suite("Speech model wording")
struct SpeechModelWordingTests {
    private func detail(
        _ status: SpeechModelStatus.State,
        phase: DictationController.Phase = .idle,
        provider: TranscriptionProviderID = .parakeet
    ) -> String {
        ModelRow.detail(status: status, phase: phase, provider: provider)
    }

    @Test("A compile is never called a download")
    func optimizingIsNotDownloading() {
        let text = detail(.optimizing)
        // The old row read "Downloading Parakeet TDT v3 — 50%" for the whole compile.
        #expect(!text.localizedCaseInsensitiveContains("download"))
        #expect(!text.contains("%"))
        // What someone staring at it needs: that it is expected, that it ends, what to do.
        #expect(text.contains("once"))
        #expect(text.contains("Leave OurWhisper running"))
    }

    @Test("A download says how far it is")
    func downloadingHasANumber() {
        #expect(detail(.downloading(0.38)).contains("38%"))
        #expect(detail(.downloading(0.38)).localizedCaseInsensitiveContains("download"))
    }

    @Test("A ready model says what it is, and a dictation in progress says what it is doing")
    func readyAndBusy() {
        #expect(detail(.ready).contains("offline"))
        #expect(detail(.ready, phase: .listening) == "Listening…")
        #expect(detail(.ready, phase: .transcribing) == "Transcribing…")
        #expect(detail(.ready, phase: .formatting) == "Cleaning up…")
    }

    @Test("A failure shows its own message, and a dictation error shows over a ready model")
    func failures() {
        #expect(detail(.failed("The Internet connection appears to be offline.")) == "The Internet connection appears to be offline.")
        #expect(detail(.ready, phase: .failed("Nothing was said")) == "Nothing was said")
    }

    @Test("A model that is not loaded says how to get it, and does not claim to be running")
    func notLoaded() {
        let text = detail(.notLoaded)
        #expect(text.contains("not loaded"))
        #expect(!text.contains("running"))
    }

    @Test("The cloud engine's row does not care what the local model is doing")
    func cloudIgnoresTheLocalModel() {
        let text = detail(.optimizing, provider: .soniox)
        #expect(text.contains("Soniox"))
        #expect(!text.localizedCaseInsensitiveContains("optimiz"))
    }
}

@Suite("Elapsed clock")
struct ElapsedClockTests {
    @Test("Seconds read as minutes and seconds", arguments: [
        (0.0, "0:00"), (9.9, "0:09"), (60.0, "1:00"), (61.0, "1:01"), (599.0, "9:59"),
        (3600.0, "60:00"),
        // A clock that starts a moment in the future must not show a minus sign.
        (-5.0, "0:00"),
    ])
    func formats(seconds: Double, expected: String) {
        #expect(ElapsedClock.format(seconds) == expected)
    }
}
