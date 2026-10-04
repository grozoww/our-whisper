import AppKit
import SwiftUI

/// The colour of a mode's icon: thirty to choose from, because someone with a dozen modes needs
/// more than five ways to tell them apart in a list.
///
/// A type of its own and not more cases on `AccentTint`. That one is the *app's* accent — the
/// switches, the selection, the sidebar highlight — and five is plenty there; growing it would put
/// thirty entries in the Configuration screen's accent menu.
///
/// The first five raw values are the old `AccentTint` ones, unchanged, so a modes file written
/// before this existed decodes to exactly the colours it had, and they still draw from the same
/// system colours. A raw value this version does not know — a hand-edited file, or one written by
/// a newer version — decodes to the mode's default blue through `Mode.init(from:)` rather than
/// failing the file.
///
/// Every colour carries a white glyph in `SectionIcon`, so none of them is light: a pale yellow
/// would be a fine swatch and an unreadable icon.
enum ModeColor: String, Codable, CaseIterable, Identifiable, Sendable {
    // The grid reads in rows of `ModeColor.columns`, so the order here is the layout. Vivid first,
    // then the in-between tones, then the deep and quiet ones.
    case red, orange, gold, lime, green, teal, sky, blue, indigo, purple
    case pink, magenta, coral, brown, moss, emerald, petrol, periwinkle, violet, plum
    case crimson, terracotta, mustard, pine, navy, ink, grape, slate, graphite, stone

    var id: String { rawValue }

    /// Colours per row of the picker.
    static let columns = 10

    /// `allCases` cut into the picker's rows.
    static var rows: [[ModeColor]] {
        stride(from: 0, to: allCases.count, by: columns).map {
            Array(allCases[$0..<min($0 + columns, allCases.count)])
        }
    }

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        // The five that predate this palette keep the system colours they always had, which also
        // follow the appearance. Graphite is `darkGray` and not a hex for the same reason.
        case .orange: .orange
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        case .graphite: Color(nsColor: .darkGray)

        case .red: Color(hex: 0xFF3B30)
        case .gold: Color(hex: 0xE2A200)
        case .lime: Color(hex: 0x6FAF1A)
        case .teal: Color(hex: 0x00A396)
        case .sky: Color(hex: 0x2FA8E0)
        case .indigo: Color(hex: 0x5856D6)

        case .pink: Color(hex: 0xFF2D55)
        case .magenta: Color(hex: 0xC2379D)
        case .coral: Color(hex: 0xF2634D)
        case .brown: Color(hex: 0xA2845E)
        case .moss: Color(hex: 0x6B8E23)
        case .emerald: Color(hex: 0x1E9E6A)
        case .petrol: Color(hex: 0x1F7A8C)
        case .periwinkle: Color(hex: 0x6C7CE6)
        case .violet: Color(hex: 0x7D4CDB)
        case .plum: Color(hex: 0x8E3F8E)

        case .crimson: Color(hex: 0xB3202A)
        case .terracotta: Color(hex: 0xB5543C)
        case .mustard: Color(hex: 0xB8860B)
        case .pine: Color(hex: 0x1F6B4A)
        case .navy: Color(hex: 0x1F3F8F)
        case .ink: Color(hex: 0x34385C)
        case .grape: Color(hex: 0x5B2A86)
        case .slate: Color(hex: 0x5F6B7A)
        case .stone: Color(hex: 0x7D7D82)
        }
    }
}

private extension Color {
    /// sRGB from a `0xRRGGBB` literal.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
