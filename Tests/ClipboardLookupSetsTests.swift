import Foundation
import Testing

@testable import OurWhisper

/// The sentences the clipboard lookup is scored on, and the examples it is shown.
///
/// What the model does with them is `./scripts/eval-clipboard.sh`, which CI cannot run. What is here
/// is what keeps that measurement honest: a sentence that is also an example is a question the model
/// has already been given the answer to, and one measured twice under two names counts double.
@Suite("Clipboard lookup: examples and measurement sets")
struct ClipboardLookupSetsTests {
    private static let files = [
        "scripts/clipboard-requests.tsv",
        "scripts/clipboard-requests-intl.tsv",
        "scripts/clipboard-requests-intl-heldout.tsv",
    ]

    private static func sentences(in file: String) throws -> [(label: String, text: String)] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(file)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { line in
                let cells = line.split(separator: "\t", maxSplits: 1).map(String.init)
                return cells.count == 2 ? (cells[0], cells[1]) : nil
            }
    }

    /// The sentence inside an example's prompt.
    private static func sentence(of example: OnDeviceRefiner.Example) -> String {
        let start = example.prompt.range(of: "<<<TRANSCRIPT\n")!.upperBound
        let end = example.prompt.range(of: "\nTRANSCRIPT>>>")!.lowerBound
        return String(example.prompt[start..<end])
    }

    @Test("Every measurement file parses, with only P and N labels", arguments: files)
    func parses(file: String) throws {
        let rows = try Self.sentences(in: file)
        #expect(rows.count >= 40, "\(file) has only \(rows.count) sentences")
        #expect(rows.allSatisfy { ["P", "N"].contains($0.label) })
        // Both kinds, or the score cannot say anything about one of the errors.
        #expect(rows.contains { $0.label == "P" } && rows.contains { $0.label == "N" })
    }

    @Test("No sentence appears in two places")
    func noSentenceTwice() throws {
        var seen: [String: String] = [:]
        for file in Self.files {
            for row in try Self.sentences(in: file) {
                if let earlier = seen[row.text] {
                    Issue.record("\"\(row.text)\" is in both \(earlier) and \(file)")
                }
                seen[row.text] = file
            }
        }
    }

    @Test("No measured sentence is also an example")
    func measuredSentencesAreNotExamples() throws {
        let examples = Set(OnDeviceRefiner.requestExamples.map(Self.sentence))
        for file in Self.files {
            for row in try Self.sentences(in: file) where examples.contains(row.text) {
                Issue.record("\"\(row.text)\" in \(file) is one of the lookup's own examples")
            }
        }
    }

    @Test("Every example's answer is one the parser accepts for its own sentence")
    func examplesAnswerThemselves() {
        for example in OnDeviceRefiner.requestExamples {
            let text = Self.sentence(of: example)
            if example.reply.hasPrefix("PASTE:") {
                // The quoted words have to be in the sentence, or the lookup would be taught to
                // answer with words it then discards.
                #expect(OnDeviceRefiner.request(from: example.reply, in: text) != nil, "\(text) -> \(example.reply)")
            } else {
                #expect(
                    example.reply == "NONE" || example.reply.hasPrefix("COPY:") || example.reply.hasPrefix("OTHER:"),
                    "\(example.reply) is not a label"
                )
                #expect(OnDeviceRefiner.request(from: example.reply, in: text) == nil)
            }
        }
    }

    @Test("The examples cover every answer, and no sentence is shown twice")
    func examplesAreBalanced() {
        let replies = OnDeviceRefiner.requestExamples.map(\.reply)
        for label in ["PASTE:", "COPY:", "OTHER:", "NONE"] {
            #expect(replies.contains { $0.hasPrefix(label) }, "no example answers \(label)")
        }
        let sentences = OnDeviceRefiner.requestExamples.map(Self.sentence)
        #expect(Set(sentences).count == sentences.count)
    }
}
