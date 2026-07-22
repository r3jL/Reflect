// Living Memory tokens (§3.6) — the single source of truth for the app's look.
// Values mirror design/living-memory/Reflect.dc.html exactly; never hard-code
// colors, fonts, or these dimensions in views.
import SwiftUI

enum Theme {
    // MARK: Paper (grounds)
    static let paper = OKLCH.color(0.974, 0.006, 84)
    static let paper2 = OKLCH.color(0.958, 0.008, 84)
    static let paper3 = OKLCH.color(0.930, 0.010, 82)
    static let paper4 = OKLCH.color(0.905, 0.012, 80)

    // MARK: Ink
    static let ink = OKLCH.color(0.30, 0.014, 55)
    static let ink2 = OKLCH.color(0.46, 0.012, 55)
    static let ink3 = OKLCH.color(0.62, 0.010, 58)
    static let ink4 = OKLCH.color(0.745, 0.008, 62)

    // MARK: Rules
    static let hair = OKLCH.color(0.885, 0.010, 78)
    static let hair2 = OKLCH.color(0.835, 0.012, 76)

    // MARK: Accent (terracotta)
    static let accent = OKLCH.color(0.56, 0.088, 52)
    static let accentSoft = OKLCH.color(0.70, 0.055, 54)

    // MARK: AppKit mirrors (editor internals)
    static let inkNS = OKLCH.nsColor(0.30, 0.014, 55)
    static let accentNS = OKLCH.nsColor(0.56, 0.088, 52)

    // MARK: Moods (dot color + 15%-alpha wash, §3.6)
    enum Mood: String, CaseIterable {
        case bright, warm, calm, quiet

        var dot: Color {
            switch self {
            case .bright: OKLCH.color(0.74, 0.10, 82)
            case .warm: OKLCH.color(0.64, 0.10, 45)
            case .calm: OKLCH.color(0.66, 0.06, 155)
            case .quiet: OKLCH.color(0.60, 0.045, 250)
            }
        }

        var wash: Color {
            switch self {
            case .bright: OKLCH.color(0.80, 0.075, 82, alpha: 0.15)
            case .warm: OKLCH.color(0.72, 0.08, 45, alpha: 0.15)
            case .calm: OKLCH.color(0.78, 0.05, 155, alpha: 0.15)
            case .quiet: OKLCH.color(0.72, 0.035, 250, alpha: 0.16)
            }
        }
    }

    // MARK: Layout constants (from the mockup)
    static let topBarHeight: CGFloat = 46
    static let writingColumnWidth: CGFloat = 640
    static let cornerRadius: CGFloat = 7
}
