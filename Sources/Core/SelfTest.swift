import AppKit
import AVFoundation
import Foundation
import OSLog

/// Runs a WAV file through the transcription provider and logs the result.
///
/// Exists because the interactive path cannot be exercised without Accessibility permission,
/// which a fresh checkout, a CI runner, and an automated agent all lack. This gives every one of
/// them a way to answer the only question that matters — does the model actually transcribe on
/// this machine — with one command:
///
///     OURWHISPER_SELFTEST=/path/to/speech.wav open -a OurWhisper
///
/// Set `OURWHISPER_SELFTEST_LANGUAGE` to a code such as `ru` to pin the language.
enum SelfTest {
    private static let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "selftest")

    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST"]
    }

    static var requestedLanguage: SpeechLanguage {
        guard let raw = ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_LANGUAGE"],
              let language = SpeechLanguage(rawValue: raw)
        else { return .auto }
        return language
    }

    /// Launch, say so, and quit before anything else starts.
    ///
    /// The one failure `codesign --verify` cannot see is dyld refusing to load a framework at
    /// launch: the hardened runtime checks that every library in the process was signed by the same
    /// team as the app, a signature can be perfectly valid and still fail that, and the result is a
    /// crash before `main`. An app that gets as far as this line has loaded everything it links.
    /// `package.sh` and the release workflow run it against the signed bundle, with an empty `HOME`
    /// so it reads nothing of anyone's:
    ///
    ///     OURWHISPER_SELFTEST_LAUNCH=1 OurWhisper.app/Contents/MacOS/OurWhisper
    static var onlyChecksItLaunches: Bool {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_LAUNCH"] == "1"
    }

    /// Whether to install whatever the update check finds, with nobody pressing the button.
    ///
    /// The half of `UpdateInstaller` the unit tests cannot reach — `hdiutil`, `ditto`, the swap,
    /// `open -n`, and a real signature check against the release certificate — has exactly one
    /// way to be exercised on purpose, and this is it. The build has to be signed with the release
    /// certificate and report a version older than the newest release, or there is nothing it is
    /// allowed to install:
    ///
    ///     OURWHISPER_SELFTEST_UPDATE=1 open /Applications/OurWhisper.app
    ///
    /// Then `./scripts/run.sh --logs`. Success ends the process by restarting into the new
    /// version, so a self-test that is still running has failed, and the `update` category says
    /// where.
    static var installsUpdate: Bool {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_UPDATE"] == "1"
    }

    @MainActor
    static func installUpdate(found checker: UpdateChecker, with installer: UpdateInstaller) async {
        log.info("Update self-test starting: running \(UpdateChecker.currentVersion, privacy: .public)")
        guard case .available(let release) = await checker.check(force: true) else {
            log.error("UPDATE SELFTEST FAILED: nothing newer than \(UpdateChecker.currentVersion, privacy: .public) is published")
            return
        }
        log.info("Installing \(release.version, privacy: .public)")
        await installer.install(release)
        // A successful install never gets here: the process has restarted into the new version.
        log.error("UPDATE SELFTEST FAILED: the app is still running — \(String(describing: installer.phase), privacy: .public)")
    }

    /// A sentence to clean up with the cleanup model, then quit.
    ///
    /// The model is the one part of cleanup the unit tests cannot reach: CI has no 2.8 GB file,
    /// and whether llama.cpp loads at all inside a hardened-runtime, release-signed bundle is a
    /// question only a real launch answers. Downloads the model first if it is missing:
    ///
    ///     OURWHISPER_SELFTEST_CLEANUP="ну короче я хотел сказать что э мы завтра не успеем" open -n OurWhisper.app
    ///
    /// Then `./scripts/run.sh --logs`. It quits when it is done, because quitting with the model
    /// loaded is the other thing worth proving — llama.cpp crashes on `exit` if it was not freed.
    static var requestedCleanup: String? {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_CLEANUP"]
    }

    @MainActor
    static func runCleanup(
        _ text: String,
        refiner: OnDeviceRefiner,
        modes: ModeStore,
        settings: RefinementSettings
    ) async {
        log.info("Cleanup self-test starting")
        let start = ContinuousClock.now
        await refiner.prepare()
        guard refiner.availability.isAvailable else {
            log.error("CLEANUP SELFTEST FAILED: \(refiner.availability.explanation, privacy: .public)")
            NSApplication.shared.terminate(nil)
            return
        }
        log.info("Model ready after \(String(describing: ContinuousClock.now - start), privacy: .public)")

        let mode = modes.resolve(settings: settings, frontmostBundleID: nil)
        for attempt in 1...2 {
            let begun = ContinuousClock.now
            let cleaned = await refiner.refine(
                text,
                instructions: mode.instructions,
                context: nil,
                placeClipboard: false,
                timeout: .seconds(max(1, settings.modelTimeoutSeconds))
            )
            log.info("RESULT \(attempt) [\(mode.name, privacy: .public), \(String(describing: ContinuousClock.now - begun), privacy: .public)]: \(cleaned ?? "nil, rules only", privacy: .public)")
        }
        log.info("Cleanup self-test finished; quitting")
        NSApplication.shared.terminate(nil)
    }

    static func run(path: String, language: SpeechLanguage, provider: any TranscriptionProvider) async {
        log.info("Self-test starting: \(path, privacy: .public) [\(language.rawValue, privacy: .public)]")

        do {
            let samples = try loadSamples(at: path)
            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            log.info("Loaded \(samples.count) samples (\(seconds, format: .fixed(precision: 2))s)")

            try await provider.prepare(progress: nil)

            let result = try await provider.transcribe(samples: samples, language: language)
            log.info("RESULT: \(result.text, privacy: .public)")
            log.info(
                "TIMING: audio \(result.audioDuration, format: .fixed(precision: 2))s, processing \(result.processingTime, format: .fixed(precision: 2))s, \(result.realtimeFactor, format: .fixed(precision: 1))x realtime, confidence \(result.confidence, format: .fixed(precision: 2))"
            )
            log.info("Self-test finished")
        } catch {
            log.error("SELFTEST FAILED: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads any audio file AVFoundation understands and converts it to the 16 kHz mono float
    /// the models expect — the same target `AudioCapture` produces, so the self-test exercises
    /// the real input format rather than a convenient one.
    private static func loadSamples(at path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCapture.CaptureError.converterUnavailable
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioCapture.CaptureError.converterUnavailable
        }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              )
        else {
            throw AudioCapture.CaptureError.converterUnavailable
        }

        try file.read(into: input)

        try converter.convertOnce(input, into: output)

        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
