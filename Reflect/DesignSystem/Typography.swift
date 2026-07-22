// Type roles per §3.6: Newsreader (bundled variable font) is the journal
// voice — writing, dates, numerals, and everything the AI says (italic).
// System sans (SF Pro) is the UI voice: kickers, labels, chrome.
import SwiftUI

enum Typography {
    private static let serifName = "Newsreader"

    /// Journal voice. Weight 300 at display sizes, 400 at text sizes (§3.6).
    static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(serifName, size: size).weight(weight)
    }

    static func serifItalic(_ size: CGFloat) -> Font {
        .custom(serifName, size: size).italic()
    }

    /// UI voice — system sans.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// AppKit serif for the NSTextView editor (22pt body per the design).
    static func editorFont(_ size: CGFloat = 22) -> NSFont {
        NSFont(name: serifName, size: size) ?? serifFallback(size)
    }

    private static func serifFallback(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        guard let desc = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: desc, size: size) else { return base }
        return font
    }
}

/// Letterspaced uppercase kicker — the design's smallest, quietest label.
struct Kicker: View {
    let text: String
    var color: Color = Theme.ink4

    var body: some View {
        Text(text.uppercased())
            .font(Typography.sans(11))
            .tracking(2.2)
            .foregroundStyle(color)
    }
}
