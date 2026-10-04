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

    /// Text to treat as the clipboard during the cleanup self-test, so the clipboard path can be
    /// run without touching — or needing — the real pasteboard. The mode under test gets "Paste the
    /// clipboard where you ask for it"; adding `OURWHISPER_SELFTEST_CLIPBOARD_CONTEXT=1` shows the
    /// cleanup model the clipboard as well, which is the other way a prompt can go wrong.
    static var requestedClipboard: String? {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_CLIPBOARD"]
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

        // Through the real pipeline, so what is logged is what a dictation would have pasted. The
        // switches are forced on: asking for a self-test of the model means wanting the model.
        var settings = settings
        settings.isEnabled = true
        settings.useCleanupModel = true
        var mode = modes.resolve(settings: settings, frontmostBundleID: nil)
        // This measures cleanup. Whoever runs it may have an assistant mode chosen, whose
        // instructions would answer the sentences instead of tidying them.
        if mode.kind == .assistant { mode = Mode.builtIns[0] }
        let clipboard = requestedClipboard
        if clipboard != nil {
            mode.pastesClipboard = true
            mode.usesClipboardContext = ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_CLIPBOARD_CONTEXT"] != nil
        }
        let pipeline = RefinementPipeline(onDevice: refiner)
        // As a dictation does while the person is still speaking, so what is timed is the lookup
        // and not the one-off reading of its examples.
        if clipboard != nil { await pipeline.warmUpClipboardLookup() }

        // `||` separates sentences, so one launch — one model load — covers a whole set.
        for sentence in text.components(separatedBy: "||").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            for attempt in 1...2 {
                let begun = ContinuousClock.now
                let result = await pipeline.refine(
                    sentence,
                    mode: mode,
                    settings: settings,
                    vocabulary: [],
                    language: .auto,
                    clipboard: clipboard
                )
                let pasted = ClipboardContext.substituted(mode.pastesClipboard ? clipboard : nil, into: result.text)
                log.info("RESULT \(attempt) [\(mode.name, privacy: .public), \(String(describing: ContinuousClock.now - begun), privacy: .public), model \(result.usedModel ? "yes" : "no", privacy: .public)] \"\(sentence, privacy: .public)\" -> \(result.text, privacy: .public) | pasted: \(pasted, privacy: .public)")
            }
        }
        log.info("Cleanup self-test finished; quitting")
        // A refiner made for a model override is not the app's, so the app's quit does not free it.
        refiner.shutdown()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - The assistant

    /// A file of cases for the assistant mode, run through the real answer path, then quit.
    ///
    ///     OURWHISPER_SELFTEST_ASSISTANT=scripts/assistant-cases.tsv \
    ///     OURWHISPER_SELFTEST_OUTPUT=/tmp/answers.json OurWhisper
    ///
    /// `./scripts/eval-assistant.sh` drives it and scores what comes out. The answers go to a file
    /// rather than the log: nothing the user said or copied is ever logged, and a test of free
    /// writing is mostly the text.
    static var requestedAssistant: String? {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_ASSISTANT"]
    }

    static var requestedOutput: String? {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_OUTPUT"]
    }

    /// A GGUF file to run instead of the model the app would use. Development only, and read here
    /// rather than stored in a setting: it exists so a larger model can be measured against the
    /// shipped one without shipping it, and a setting would be a way to point the app at a file
    /// nobody has checked. Works for the cleanup self-test as well, which is how the clipboard
    /// lookup is scored on a second model.
    static var modelOverride: URL? {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_MODEL"].map { URL(fileURLWithPath: $0) }
    }

    /// `refiner`, or a refiner for the override file if there is one. Never downloads anything: the
    /// file is where it is, and a model with no URL to fetch cannot be fetched.
    @MainActor
    static func refiner(replacing refiner: OnDeviceRefiner, slot: LlamaEngine.Slot) -> OnDeviceRefiner {
        guard let file = modelOverride else { return refiner }
        let model = CleanupModel(
            name: file.deletingPathExtension().lastPathComponent,
            fileName: file.lastPathComponent,
            url: file,
            bytes: 0,
            sha256: ""
        )
        return OnDeviceRefiner(model: model, slot: slot, directory: file.deletingLastPathComponent())
    }

    /// One row of the cases file.
    struct AssistantCase: Equatable, Sendable {
        var id: String
        var request: String
        var clipboard: String?
    }

    /// `id<TAB>request<TAB>clipboard<TAB>checks`, one case a line. The clipboard cell holds `\n`
    /// for a newline, and `@repeat:N:text` for N copies of a text, which is how a clipboard longer
    /// than the material limit is written without a page of it in the file. The checks are the
    /// scorer's business and are not read here.
    nonisolated static func assistantCases(from text: String) -> [AssistantCase] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count >= 3 else { return nil }
            return AssistantCase(id: cells[0], request: cells[1], clipboard: decodedClipboard(cells[2]))
        }
    }

    nonisolated static func decodedClipboard(_ cell: String) -> String? {
        if cell.isEmpty { return nil }
        if cell.hasPrefix("@repeat:") {
            let parts = cell.dropFirst("@repeat:".count).split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let count = Int(parts[0]) else { return nil }
            return String(repeating: parts[1], count: count)
        }
        return cell.replacingOccurrences(of: "\\n", with: "\n")
    }

    @MainActor
    static func runAssistant(casesPath: String, refiner: OnDeviceRefiner) async {
        log.info("Assistant self-test starting")
        guard let text = try? String(contentsOfFile: casesPath, encoding: .utf8) else {
            log.error("ASSISTANT SELFTEST FAILED: cannot read \(casesPath, privacy: .public)")
            NSApplication.shared.terminate(nil)
            return
        }

        // Only a file that is already here. `prepare()` would fetch 4.6 GB for a measurement the
        // person did not ask to pay for; the override or the Models screen is how it gets here.
        guard FileManager.default.fileExists(atPath: refiner.fileURL.path(percentEncoded: false)) else {
            log.error("ASSISTANT SELFTEST FAILED: \(refiner.model.name, privacy: .public) is not on this Mac. Download it in Models, or set OURWHISPER_SELFTEST_MODEL to a file.")
            NSApplication.shared.terminate(nil)
            return
        }
        let loading = ContinuousClock.now
        await refiner.prepare()
        guard refiner.availability.isAvailable else {
            log.error("ASSISTANT SELFTEST FAILED: \(refiner.availability.explanation, privacy: .public)")
            NSApplication.shared.terminate(nil)
            return
        }
        let loadSeconds = seconds(ContinuousClock.now - loading)
        log.info("\(refiner.model.name, privacy: .public) ready after \(loadSeconds, format: .fixed(precision: 1))s")

        let environment = ProcessInfo.processInfo.environment
        var mode = Mode.ask
        mode.thinks = environment["OURWHISPER_SELFTEST_THINK"] == "1"
        // Fixed seeds make a score repeatable; greedy is the comparison the sampling is judged by.
        let greedy = environment["OURWHISPER_SELFTEST_GREEDY"] == "1"
        let seed = environment["OURWHISPER_SELFTEST_SEED"].flatMap(UInt32.init) ?? 1
        let repeats = max(1, environment["OURWHISPER_SELFTEST_REPEAT"].flatMap(Int.init) ?? 1)
        // The shipped temperature, or another to find out whether it should move: whether a lower
        // one is steadier without turning every retry into the same text.
        let temperature = environment["OURWHISPER_SELFTEST_TEMPERATURE"].flatMap(Float.init)
            ?? LlamaEngine.Sampling.assistantTemperature

        // The pipeline a dictation uses, so the request's cleanup and the material's cap are in what
        // is measured and not a copy of them.
        let pipeline = RefinementPipeline(onDevice: refiner, assistant: refiner)

        var results: [[String: Any]] = []
        for (index, testCase) in assistantCases(from: text).enumerated() {
            for attempt in 0..<repeats {
                let sampling: LlamaEngine.Sampling = greedy
                    ? .greedy
                    : .sampled(temperature: temperature, topP: 0.95, topK: 64, seed: seed &+ UInt32(index * 31 + attempt))
                let begun = ContinuousClock.now
                var row: [String: Any] = ["id": testCase.id, "attempt": attempt]
                do {
                    let answer = try await pipeline.answer(
                        testCase.request,
                        mode: mode,
                        vocabulary: [],
                        language: .auto,
                        material: testCase.clipboard,
                        sampling: sampling
                    )
                    row["answer"] = answer.text
                    row["cut"] = answer.answerWasCut
                    row["materialCut"] = answer.materialWasCut
                    if let stats = answer.stats {
                        row["promptTokens"] = stats.promptTokens
                        row["generatedTokens"] = stats.generatedTokens
                        row["prefill"] = stats.prefill
                        row["tokensPerSecond"] = stats.tokensPerSecond
                    }
                } catch {
                    row["failure"] = error.localizedDescription
                }
                row["seconds"] = seconds(ContinuousClock.now - begun)
                results.append(row)
                log.info("CASE \(testCase.id, privacy: .public) \(attempt) \(row["failure"] == nil ? "answered" : "no answer", privacy: .public) in \(row["seconds"] as? Double ?? 0, format: .fixed(precision: 1))s")
            }
        }

        let report: [String: Any] = [
            "model": refiner.model.name,
            "loadSeconds": loadSeconds,
            "thinks": mode.thinks,
            "greedy": greedy,
            "temperature": temperature,
            "repeats": repeats,
            "results": results,
        ]
        if let path = requestedOutput,
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        log.info("Assistant self-test finished; quitting")
        refiner.shutdown()
        NSApplication.shared.terminate(nil)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
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
