import FluidAudio
import Foundation
import OSLog

/// What is on disk, how big it is, and how to get rid of it.
///
/// The speech model is a 600 MB download the app makes on first launch, and the cleanup model
/// another 2.8 GB. An app that does that without showing you where it went, what it cost, or how
/// to remove it is asking for a lot of trust. This screen is the answer: every model the app can
/// use, its state, its size, and a delete button that actually deletes.
@MainActor
@Observable
final class ModelLibrary {
    /// One row in the library.
    struct Entry: Identifiable, Sendable {
        enum Kind: Sendable {
            /// Runs on this Mac. Has a size and can be deleted.
            case local
            /// Runs on someone else's. Has an API key instead of a download.
            case cloud
        }

        enum State: Equatable, Sendable {
            case notInstalled
            /// Something is starting or loading and has no number to show.
            case preparing
            case downloading(Double)
            /// On disk, and being compiled for this Mac's Neural Engine. Not "installed": the files
            /// are all there and the model still cannot be used, which is the state a restart used
            /// to report as done.
            case optimizing
            case installed(bytes: Int64)
            case failed(String)
            /// Cloud engines: configured or not.
            case ready
            case needsKey
        }

        let id: String
        let name: String
        let vendor: String
        let kind: Kind
        let detail: String
        let languages: String
        let licence: String
        var state: State
    }

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "models")

    /// The provider that owns the speech model download, so the library can trigger and observe it
    /// rather than duplicating FluidAudio's download logic.
    private let parakeet: ParakeetProvider

    /// What the speech model is doing right now. Read live, so a preparation started at launch
    /// shows here exactly as one started from this screen does.
    private let speechModel: SpeechModelStatus

    /// The cleanup model owns its own download and load. Its row is read from it on every render
    /// rather than copied, so a download started at launch or from Configuration shows its
    /// progress here too.
    private let cleanup: OnDeviceRefiner

    /// Set by `AppState`. Downloading or removing the cleanup model here is also a decision about
    /// the switch in Configuration, and the two must not disagree: removing it while the switch is
    /// on would have the app fetch the 2.8 GB again at the next launch, and downloading it with the
    /// switch off would load a model nothing is allowed to use.
    var setCleanupModelEnabled: ((Bool) -> Void)?

    /// Where the speech model's files are, and so what Remove deletes.
    let parakeetDirectory: URL

    /// What the disk says about the speech model: its size, or `nil` when the files are not there.
    /// Stored, because walking a directory is not something a view body may do — `refresh()` is
    /// where it happens.
    private var speechModelBytes: Int64?
    private var sonioxState: Entry.State = .needsKey

    /// - Parameter parakeetDirectory: Injected so a test can remove "the speech model" without it
    ///   being the real one. See `defaultParakeetDirectory`.
    init(
        parakeet: ParakeetProvider,
        speechModel: SpeechModelStatus,
        cleanup: OnDeviceRefiner,
        parakeetDirectory: URL = ModelLibrary.defaultParakeetDirectory
    ) {
        self.parakeet = parakeet
        self.speechModel = speechModel
        self.cleanup = cleanup
        self.parakeetDirectory = parakeetDirectory
    }

    // MARK: - Catalogue

    static let parakeetID = "parakeet-tdt-0.6b-v3"
    static let sonioxID = "soniox-cloud"
    static let gemmaID = "gemma-4-e2b-it"

    var entries: [Entry] {
        [Self.parakeetEntry(state: speechModelState), Self.sonioxEntry(state: sonioxState)]
    }

    /// The speech model's row: the live status when something is going on, the disk when nothing
    /// is. "Installed" only means the files are there, so it is what is shown only when the model
    /// is not being prepared and has not failed — and `.ready` is the one state that proves it.
    private var speechModelState: Entry.State {
        switch speechModel.state {
        case .starting: .preparing
        case .downloading(let fraction): .downloading(fraction)
        case .optimizing: .optimizing
        case .failed(let message): .failed(message)
        case .ready: .installed(bytes: speechModelBytes ?? 0)
        case .notLoaded: speechModelBytes.map { .installed(bytes: $0) } ?? .notInstalled
        }
    }

    /// The language model behind "Clean up with Gemma 4".
    var cleanupEntry: Entry {
        let state: Entry.State = switch cleanup.availability {
        case .notDownloaded: .notInstalled
        case .downloading(let fraction): .downloading(fraction)
        case .loading: .preparing
        case .downloaded, .available: .installed(bytes: OnDeviceRefiner.model.bytes)
        case .failed(let message): .failed(message)
        }
        return Entry(
            id: Self.gemmaID,
            name: OnDeviceRefiner.model.name,
            vendor: "Google",
            kind: .local,
            detail: "Cleans up transcripts. Runs on this Mac's GPU through llama.cpp, never leaves this Mac.",
            languages: "35+ languages",
            licence: "Apache-2.0",
            state: state
        )
    }

    private static func parakeetEntry(state: Entry.State) -> Entry {
        Entry(
            id: parakeetID,
            name: "Parakeet TDT 0.6B v3",
            vendor: "NVIDIA",
            kind: .local,
            detail: "The default. Runs on the Neural Engine, never leaves this Mac.",
            languages: "25 European languages",
            licence: "CC-BY-4.0",
            state: state
        )
    }

    private static func sonioxEntry(state: Entry.State) -> Entry {
        Entry(
            id: sonioxID,
            name: "Soniox",
            vendor: "Soniox",
            kind: .cloud,
            detail: "Optional. Covers the languages Parakeet cannot, including Chinese and Japanese.",
            languages: "60+ languages",
            licence: "Your own API key, billed by Soniox",
            state: state
        )
    }

    // MARK: - State

    /// Where FluidAudio keeps the speech model. Asked for rather than hardcoded, so the path stays
    /// right if the library changes it.
    ///
    /// Redirected under test, and that is a backstop for a mistake that was made: this folder is
    /// FluidAudio's, outside `AppDirectories.support`, so the redirect that protects every other
    /// file the app writes does not reach it. A test that pressed Remove on the speech model deleted
    /// the real 600 MB one, and the only sign was a re-download at the next launch.
    static var defaultParakeetDirectory: URL {
        AppDirectories.isRunningTests
            ? AppDirectories.support.appendingPathComponent("SpeechModel", isDirectory: true)
            : AsrModels.defaultCacheDirectory(for: .v3)
    }

    func refresh() {
        speechModelBytes = AsrModels.modelsExist(at: parakeetDirectory)
            ? AppDirectories.size(of: parakeetDirectory)
            : nil
        sonioxState = KeychainStore.has(.soniox) ? .ready : .needsKey
    }

    // MARK: - Actions

    func download(_ id: String) async {
        if id == Self.gemmaID {
            setCleanupModelEnabled?(true)
            return await cleanup.prepare()
        }
        guard id == Self.parakeetID else { return }

        do {
            try await speechModel.prepare(using: parakeet)
            log.info("Speech model downloaded")
        } catch {
            log.error("Speech model download failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    /// Unloads the model before deleting the files. Deleting CoreML models out from under a loaded
    /// `MLModel` is how you get a crash on the next dictation instead of a clean "not installed".
    func remove(_ id: String) async {
        if id == Self.gemmaID {
            setCleanupModelEnabled?(false)
            return await cleanup.remove()
        }
        guard id == Self.parakeetID else { return }
        await parakeet.unload()
        try? FileManager.default.removeItem(at: parakeetDirectory)
        speechModel.reset()
        log.info("Speech model removed")
        refresh()
    }
}
