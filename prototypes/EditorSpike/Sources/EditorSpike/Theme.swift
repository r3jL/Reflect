// Living Memory tokens (§3.6) — sRGB approximations of the OKLCH values,
// good enough for the spike; the real app converts OKLCH exactly.
import SwiftUI

enum Theme {
    static let paper = Color(hex: 0xF8F6F1)
    static let paper2 = Color(hex: 0xF3F0EA)
    static let ink = Color(hex: 0x3C342D)
    static let ink2 = Color(hex: 0x645C54)
    static let ink3 = Color(hex: 0x8D857C)
    static let ink4 = Color(hex: 0xAFA9A0)
    static let hair = Color(hex: 0xDED8CD)
    static let accent = Color(hex: 0xA56B45)
    static let accentSoft = Color(hex: 0xC39B7E)

    static let inkNS = NSColor(srgbRed: 0x3C / 255, green: 0x34 / 255, blue: 0x2D / 255, alpha: 1)
    static let accentNS = NSColor(srgbRed: 0xA5 / 255, green: 0x6B / 255, blue: 0x45 / 255, alpha: 1)

    /// System serif (New York) stands in for Newsreader until fonts are bundled.
    static func serif(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let desc = base.fontDescriptor.withDesign(.serif),
              let font = NSFont(descriptor: desc, size: size) else { return base }
        return font
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}
