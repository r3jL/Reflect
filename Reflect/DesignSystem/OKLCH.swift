// OKLCH → sRGB conversion (Björn Ottosson's OKLab reference math).
// The Living Memory tokens (§3.6) are authored in OKLCH; converting at
// runtime keeps the spec values the single source of truth.
import SwiftUI

enum OKLCH {
    /// `oklch(l c h)` exactly as written in the design's CSS.
    static func color(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) -> Color {
        let (r, g, b) = srgb(l: l, c: c, h: h)
        return Color(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    static func nsColor(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) -> NSColor {
        let (r, g, b) = srgb(l: l, c: c, h: h)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    private static func srgb(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let hRad = h * .pi / 180
        let a = c * cos(hRad)
        let b = c * sin(hRad)

        // OKLab → LMS (cube roots undone)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_
        let mc = m_ * m_ * m_
        let sc = s_ * s_ * s_

        // LMS → linear sRGB
        let rLin = +4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let gLin = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bLin = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

        return (encode(rLin), encode(gLin), encode(bLin))
    }

    private static func encode(_ linear: Double) -> Double {
        let v = max(0, min(1, linear))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }
}
