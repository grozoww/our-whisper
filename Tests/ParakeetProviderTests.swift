import FluidAudio
import Foundation
import Testing

@testable import OurWhisper

/// What happens to the speech model's files when loading them fails.
///
/// The report was "the Mac restarted for an update, the app started with it, and it lost the models
/// and downloaded them again — closing and opening it by hand never does". FluidAudio deletes the
/// whole model folder on any failed load that is not a cancellation or a network error, so a load
/// that fails while the Mac is still starting up takes 600 MB with it, and the re-download then
/// fails for want of a network. These tests hold the files still.
@Suite("Parakeet provider")
struct ParakeetProviderTests {
    /// A cache that has every file FluidAudio asks for and none of them a model: each `.mlmodelc`
    /// has the layout of one and the bytes of nothing, so CoreML refuses it — the same error, to
    /// the caller, as a Mac that was too busy to load a real one.
    private func fakeCache(in root: TemporaryDirectory) throws -> URL {
        let folder = root.url
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        for name in ModelNames.ASR.requiredModelsV3(precision: .int8) {
            let path = folder.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("not a model".utf8).write(to: path.appendingPathComponent("coremldata.bin"))
        }
        try Data("{}".utf8).write(to: folder.appendingPathComponent(ModelNames.ASR.vocabularyFile))
        return folder
    }

    @Test("A model that will not load keeps its files, and is not turned into a download")
    func failedLoadKeepsFiles() async throws {
        let root = TemporaryDirectory()
        let folder = try fakeCache(in: root)
        let sentinel = folder.appendingPathComponent("not-a-model.txt")
        try Data("still here".utf8).write(to: sentinel)
        try #require(AsrModels.modelsExist(at: folder), "the stand-in cache is not one FluidAudio accepts")

        let provider = ParakeetProvider(directory: folder)

        // If this ever fails to throw, the stand-in was accepted as a model and the rest proves
        // nothing. If the protection is removed instead, FluidAudio deletes the folder and goes to
        // the network for a real one, and the sentinel below is what notices.
        await #expect(throws: TranscriptionError.self) { try await provider.prepare() }

        #expect(FileManager.default.fileExists(atPath: sentinel.path), "FluidAudio deleted the model folder")
        for name in ModelNames.ASR.requiredModelsV3(precision: .int8) {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was deleted")
        }
        #expect(await provider.isReady == false)
    }

    @Test("The offline switch is never left on, because it would stop every later download")
    func offlineSwitchIsReleased() async throws {
        let root = TemporaryDirectory()
        let provider = ParakeetProvider(directory: try fakeCache(in: root))

        _ = try? await provider.prepare()

        #expect(ModelHub.offlineMode == false)
    }

    @Test("Files on disk are told from an empty folder, which is what decides whether a load is retried")
    func isOnDisk() throws {
        let root = TemporaryDirectory()
        let empty = root.url.appendingPathComponent("Models/parakeet-tdt-0.6b-v3", isDirectory: true)
        #expect(ParakeetProvider(directory: empty).isOnDisk == false)

        let populated = TemporaryDirectory()
        #expect(ParakeetProvider(directory: try fakeCache(in: populated)).isOnDisk)
    }

    @Test("A model that is retried is retried a few times and then left to the person")
    func retryScheduleIsShort() {
        #expect(DictationController.loadRetryDelays.count == 3)
        #expect(DictationController.loadRetryDelays == DictationController.loadRetryDelays.sorted())
        #expect(DictationController.loadRetryDelays.last! <= .seconds(300))
    }
}
