import FluidAudio
import Foundation
import Testing

@testable import OurWhisper

/// What the Models screen says about each model, and what pressing its buttons also decides.
///
/// The library's speech model row used to be a copy of the disk, taken when the screen opened.
/// That is how it came to say "installed" for files that were all there while the model was still
/// being compiled and could not be used.
@Suite("Models library")
@MainActor
struct ModelLibraryTests {
    private func library(
        speech: SpeechModelStatus.State = .notLoaded,
        cleanup: OnDeviceRefiner.Availability? = nil,
        http: any HTTPClient = StubHTTPClient(script: []),
        directory: TemporaryDirectory
    ) -> ModelLibrary {
        ModelLibrary(
            parakeet: ParakeetProvider(),
            speechModel: SpeechModelStatus(state: speech),
            cleanup: OnDeviceRefiner(directory: directory.url, http: http, availability: cleanup),
            // Always the temporary one. `remove` deletes this folder, and the default is the real
            // speech model — an earlier version of this suite deleted it.
            parakeetDirectory: directory.url.appendingPathComponent("SpeechModel", isDirectory: true)
        )
    }

    // MARK: - The speech model's row

    @Test("The speech model's row says what the model is doing, not what is on disk", arguments: [
        (SpeechModelStatus.State.starting, ModelLibrary.Entry.State.preparing),
        (.downloading(0.38), .downloading(0.38)),
        // The state a restart used to report as done.
        (.optimizing, .optimizing),
        (.failed("offline"), .failed("offline")),
    ])
    func followsTheStatus(status: SpeechModelStatus.State, row: ModelLibrary.Entry.State) {
        let temp = TemporaryDirectory()
        #expect(library(speech: status, directory: temp).entries[0].state == row)
    }

    @Test("Only a model that is ready, or one nobody is touching, can be called installed")
    func installedIsEarned() {
        let temp = TemporaryDirectory()
        // Not loaded, and no files seen: not installed. Ready: installed, whatever the disk walk
        // has not yet found out.
        #expect(library(speech: .notLoaded, directory: temp).entries[0].state == .notInstalled)
        #expect(library(speech: .ready, directory: temp).entries[0].state == .installed(bytes: 0))
    }

    @Test("The cloud row is not affected by any of it")
    func cloudRowIsItsOwn() {
        let temp = TemporaryDirectory()
        #expect(library(speech: .optimizing, directory: temp).entries[1].id == ModelLibrary.sonioxID)
    }

    // MARK: - The cleanup model's row

    @Test("The cleanup model's row follows its availability", arguments: [
        (OnDeviceRefiner.Availability.notDownloaded, ModelLibrary.Entry.State.notInstalled),
        (.downloading(0.4), .downloading(0.4)),
        (.downloaded, .installed(bytes: CleanupModel.gemma4E2B.bytes)),
        // Loading is twelve seconds with nothing to count, and is not "installed" yet.
        (.loading, .preparing),
        (.available, .installed(bytes: CleanupModel.gemma4E2B.bytes)),
        (.failed("no"), .failed("no")),
    ])
    func cleanupRow(availability: OnDeviceRefiner.Availability, row: ModelLibrary.Entry.State) {
        let temp = TemporaryDirectory()
        #expect(library(cleanup: availability, directory: temp).cleanupEntry.state == row)
    }

    // MARK: - The button is also the switch

    @Test("Removing the cleanup model switches it off, so the next launch does not fetch it again")
    func removingSwitchesOff() async {
        let temp = TemporaryDirectory()
        let library = library(cleanup: .downloaded, directory: temp)
        var choices: [Bool] = []
        library.setCleanupModelEnabled = { choices.append($0) }

        await library.remove(ModelLibrary.gemmaID)

        #expect(choices == [false])
        #expect(library.cleanupEntry.state == .notInstalled)
    }

    @Test("Downloading the cleanup model switches it on, so what is fetched is allowed to be used")
    func downloadingSwitchesOn() async {
        let temp = TemporaryDirectory()
        // Nothing scripted: the request fails at once, which is all this needs. What is asserted is
        // the choice, made before the work starts.
        let library = library(directory: temp)
        var choices: [Bool] = []
        library.setCleanupModelEnabled = { choices.append($0) }

        await library.download(ModelLibrary.gemmaID)

        #expect(choices == [true])
    }

    // MARK: - Remove deletes what it was given and nothing else

    @Test("Removing the speech model deletes its folder and only its folder")
    func removeDeletesOnlyItsOwnFolder() async throws {
        let temp = TemporaryDirectory()
        let library = library(directory: temp)
        let folder = library.parakeetDirectory
        let neighbour = temp.url.appendingPathComponent("SomethingElse", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: folder.appendingPathComponent("Encoder.mlmodelc"))

        await library.remove(ModelLibrary.parakeetID)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
    }

    @Test("Under test the default speech model folder is not the real one")
    func defaultIsNotTheRealFolder() {
        // The backstop. A test that forgets to pass a folder still must not be able to reach the
        // user's 600 MB model: it lives outside `AppDirectories.support`, which is what redirects
        // everything else.
        #expect(ModelLibrary.defaultParakeetDirectory != AsrModels.defaultCacheDirectory(for: .v3))
        #expect(ModelLibrary.defaultParakeetDirectory.path.hasPrefix(AppDirectories.support.path))
    }

    @Test("Removing or downloading the speech model says nothing about the cleanup switch")
    func speechModelIsNotTheSwitch() async {
        let temp = TemporaryDirectory()
        let library = library(directory: temp)
        var choices: [Bool] = []
        library.setCleanupModelEnabled = { choices.append($0) }

        await library.remove(ModelLibrary.parakeetID)

        #expect(choices.isEmpty)
    }
}
