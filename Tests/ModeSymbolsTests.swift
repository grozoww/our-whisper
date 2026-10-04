import AppKit
import Foundation
import Testing

@testable import OurWhisper

/// The icon catalogue is a hand-written list, so what keeps it honest is these tests: a typo in a
/// name draws an empty square on someone's Mac, and nothing else would notice.
@Suite("Mode icon catalogue")
@MainActor
struct ModeSymbolsTests {
    @Test("Every name resolves to a real symbol on this system", arguments: ModeSymbols.all.map(\.name))
    func everyNameResolves(name: String) {
        // The system running the tests is not the oldest one the app supports, so this catches a
        // typo but not a name that arrived in a newer SF Symbols release than macOS 15 has. Those
        // were checked against the availability table when the list was written.
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not an SF Symbol")
    }

    @Test("No name appears twice")
    func namesAreUnique() {
        let names = ModeSymbols.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("Every entry can be found in English and in Russian", arguments: ModeSymbols.all)
    func entriesAreSearchableInBothLanguages(symbol: ModeSymbol) {
        func has(_ range: ClosedRange<Unicode.Scalar>, in word: String) -> Bool {
            word.unicodeScalars.contains { range.contains($0) }
        }
        #expect(symbol.keywords.contains { has("a"..."z", in: $0) }, "\(symbol.name) has no English keyword")
        #expect(symbol.keywords.contains { has("\u{0400}"..."\u{04FF}", in: $0) }, "\(symbol.name) has no Cyrillic keyword")
    }

    @Test("Every category has something in it", arguments: ModeSymbol.Category.allCases)
    func categoriesAreNotEmpty(category: ModeSymbol.Category) {
        #expect(!ModeSymbols.symbols(in: category).isEmpty)
    }

    @Test("A new mode starts with an icon that is in the catalogue")
    func newModesStartOnTheCatalogue() {
        let temp = TemporaryDirectory()
        let store = ModeStore(directory: temp.url)
        #expect(ModeSymbols.symbol(named: store.add().symbol) != nil)
    }

    @Test("Every shipped mode wears an icon from the catalogue", arguments: Mode.builtIns)
    func builtInModesUseTheCatalogue(mode: Mode) {
        #expect(ModeSymbols.symbol(named: mode.symbol) != nil, "\(mode.name) uses \(mode.symbol)")
    }

    // MARK: - Search

    @Test("A Russian word finds the envelope")
    func searchesRussian() {
        #expect(ModeSymbols.search("почта").first?.name == "envelope")
    }

    @Test("A Ukrainian word finds it too")
    func searchesUkrainian() {
        #expect(ModeSymbols.search("пошта").map(\.name).contains("envelope"))
    }

    @Test("An English word finds it")
    func searchesEnglish() {
        #expect(ModeSymbols.search("email").map(\.name).contains("envelope"))
    }

    @Test("Part of a word is enough")
    func searchesByPrefix() {
        #expect(ModeSymbols.search("поч").map(\.name).contains("envelope"))
        #expect(ModeSymbols.search("env").map(\.name).contains("envelope"))
    }

    @Test("The symbol's own name is searchable, in pieces")
    func searchesByName() {
        // Someone who does know a name should not have to know the keywords as well.
        #expect(ModeSymbols.search("curlybraces").map(\.name).contains("curlybraces"))
        #expect(ModeSymbols.search("forwardslash").map(\.name).contains("chevron.left.forwardslash.chevron.right"))
    }

    @Test("Case, accents and ё do not matter")
    func foldsCaseAndAccents() {
        #expect(ModeSymbols.search("ПОЧТА").first?.name == "envelope")
        #expect(ModeSymbols.search("ёлка") == ModeSymbols.search("елка"))
        #expect(ModeSymbols.search("  Mail  ").map(\.name).contains("envelope"))
    }

    @Test("Every word typed has to match")
    func everyWordMustMatch() {
        #expect(ModeSymbols.search("mail letter").map(\.name).contains("envelope"))
        #expect(ModeSymbols.search("mail nonsenseword").isEmpty)
    }

    @Test("An exact word outranks a longer one that merely starts with it")
    func exactBeatsPrefix() {
        // "key" is a whole keyword of the key symbol and only the start of "keyboard"-like words.
        #expect(ModeSymbols.search("key").first?.name == "key")
    }

    @Test("An empty search shows everything, in the catalogue's order")
    func emptyQueryIsEverything() {
        #expect(ModeSymbols.search("") == ModeSymbols.all)
        #expect(ModeSymbols.search("   ") == ModeSymbols.all)
    }

    @Test("A search that matches nothing finds nothing")
    func noMatch() {
        #expect(ModeSymbols.search("zzzzqqqq").isEmpty)
    }

    // MARK: - Names that are not on the list

    @Test("A name outside the catalogue still resolves if the system has it")
    func customNames() {
        #expect(ModeSymbols.symbol(named: "tortoise") == nil)
        #expect(ModeSymbols.resolves("tortoise"))
        #expect(!ModeSymbols.resolves("not.a.symbol.at.all"))
        #expect(!ModeSymbols.resolves(""))
    }
}

/// The palette is a hand-written list too, and its raw values are what a modes file stores.
@Suite("Mode colours")
struct ModeColorTests {
    @Test("There are enough colours to tell a dozen modes apart")
    func thereAreManyColours() {
        #expect(ModeColor.allCases.count >= 24)
    }

    @Test("The picker's rows are all full, so the grid has no ragged edge")
    func rowsAreFull() {
        #expect(ModeColor.allCases.count % ModeColor.columns == 0)
        #expect(ModeColor.rows.allSatisfy { $0.count == ModeColor.columns })
    }

    @Test("The five colours that predate the palette are still in it")
    func originalFiveSurvive() {
        // Their names are on disk in every modes file ever written. Renaming one loses the colour.
        for name in ["orange", "blue", "purple", "green", "graphite"] {
            #expect(ModeColor(rawValue: name) != nil, "\(name) was removed")
        }
    }

    @Test("Every colour has a name to show as its tooltip", arguments: ModeColor.allCases)
    func titles(color: ModeColor) {
        #expect(!color.title.isEmpty)
    }
}
