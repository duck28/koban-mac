import AppKit
import SwiftUI

/// "Paper & Ink" design tokens, 1:1 with the CSS variables in src/App.css.
/// All four palettes (Zen, Monochrome, Slate, Forest) in light ("Washi") and dark ("Sumi").
struct ZenTokens {
    var app, surface, raised, line, ink, ink2, ink3, accent, positive, indigo, warning, viewer, onInk: UInt32
}

enum Zen {
    /// Active palette (AppSettings.themePalette). RootView re-identifies its tree when it changes,
    /// so every token is re-resolved.
    nonisolated(unsafe) static var palette: ThemePalette = .zen

    static func tokens(_ palette: ThemePalette, dark: Bool) -> ZenTokens {
        switch (palette, dark) {
        case (.zen, false):
            return ZenTokens(app: 0xF5F3EE, surface: 0xFBFAF7, raised: 0xEEEBE4, line: 0xE3DFD6, ink: 0x1F1E1C,
                             ink2: 0x5F5B54, ink3: 0x9B968D, accent: 0xB9432F, positive: 0x3F704D, indigo: 0x3F6E8C,
                             warning: 0xB8862D, viewer: 0xE8E5DE, onInk: 0xFBFAF7)
        case (.zen, true):
            return ZenTokens(app: 0x141413, surface: 0x1A1A18, raised: 0x262522, line: 0x2D2C29, ink: 0xEBE7DF,
                             ink2: 0xAAA59B, ink3: 0x6F6B64, accent: 0xE0644C, positive: 0x68A878, indigo: 0x679BC0,
                             warning: 0xE0A94C, viewer: 0x0F0F0E, onInk: 0x161614)
        case (.monochrome, false):
            return ZenTokens(app: 0xF6F6F6, surface: 0xFFFFFF, raised: 0xE8E8E8, line: 0xCCCCCC, ink: 0x000000,
                             ink2: 0x383838, ink3: 0x757575, accent: 0x111111, positive: 0x262626, indigo: 0x404040,
                             warning: 0x616161, viewer: 0xEAEAEA, onInk: 0xFFFFFF)
        case (.monochrome, true):
            return ZenTokens(app: 0x080808, surface: 0x111111, raised: 0x1C1C1C, line: 0x2B2B2B, ink: 0xFDFDFD,
                             ink2: 0xADADAD, ink3: 0x6E6E6E, accent: 0xFFFFFF, positive: 0xE5E5E5, indigo: 0xCCCCCC,
                             warning: 0x999999, viewer: 0x000000, onInk: 0x000000)
        case (.slate, false):
            return ZenTokens(app: 0xF1F5F9, surface: 0xFFFFFF, raised: 0xE2E8F0, line: 0xCBD5E1, ink: 0x0F172A,
                             ink2: 0x475569, ink3: 0x94A3B8, accent: 0x0284C7, positive: 0x059669, indigo: 0x3B82F6,
                             warning: 0xD97706, viewer: 0xE2E8F0, onInk: 0xFFFFFF)
        case (.slate, true):
            return ZenTokens(app: 0x0B0F17, surface: 0x111827, raised: 0x1E293B, line: 0x334155, ink: 0xF8FAFC,
                             ink2: 0x94A3B8, ink3: 0x64748B, accent: 0x38BDF8, positive: 0x34D399, indigo: 0x60A5FA,
                             warning: 0xFBBF24, viewer: 0x070A0F, onInk: 0x0B0F17)
        case (.forest, false):
            return ZenTokens(app: 0xF2F5F1, surface: 0xFAFBFA, raised: 0xE3EAE1, line: 0xCED7CC, ink: 0x142217,
                             ink2: 0x485C4C, ink3: 0x87998B, accent: 0x1E5A38, positive: 0x2E7D32, indigo: 0x2C6E64,
                             warning: 0xC28100, viewer: 0xE3EAE1, onInk: 0xFFFFFF)
        case (.forest, true):
            return ZenTokens(app: 0x0C1410, surface: 0x13201A, raised: 0x1C2E25, line: 0x273E33, ink: 0xF0F7F2,
                             ink2: 0x9DB5A3, ink3: 0x5F7A67, accent: 0x34D399, positive: 0x4ADE80, indigo: 0x2DD4BF,
                             warning: 0xFACC15, viewer: 0x080D0A, onInk: 0x0C1410)
        }
    }

    static var app: Color { token(\.app) }          // window background
    static var surface: Color { token(\.surface) }  // bars, cards & panels
    static var raised: Color { token(\.raised) }    // hover, inputs, active tool
    static var line: Color { token(\.line) }        // hairlines
    static var ink: Color { token(\.ink) }          // primary text & icons
    static var ink2: Color { token(\.ink2) }        // secondary text
    static var ink3: Color { token(\.ink3) }        // muted text, placeholders
    static var accent: Color { token(\.accent) }    // vermilion seal / over budget
    static var positive: Color { token(\.positive) } // moss green
    static var indigo: Color { token(\.indigo) }    // freelancer accent
    static var warning: Color { token(\.warning) }  // gold ochre
    static var viewer: Color { token(\.viewer) }    // backdrop
    static var onInk: Color { token(\.onInk) }      // text on ink buttons

    /// Tokens are read thousands of times per render. Building a new dynamic NSColor each time
    /// allocated a closure-backed color per access and made every Color compare unequal, so SwiftUI
    /// could never skip redrawing. Colors are now created once per palette and reused.
    nonisolated(unsafe) private static var cache: [ThemePalette: [KeyPath<ZenTokens, UInt32>: Color]] = [:]

    private static func token(_ keyPath: KeyPath<ZenTokens, UInt32> & Sendable) -> Color {
        let palette = Zen.palette
        if let color = cache[palette]?[keyPath] { return color }
        let color = Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: tokens(palette, dark: isDark)[keyPath: keyPath])
        })
        cache[palette, default: [:]][keyPath] = color
        return color
    }

    /// Green for favorable, vermilion for unfavorable, muted for ~0 (the worksheet's diff coloring).
    static func diff(_ value: Double) -> Color {
        value > 0.004 ? positive : (value < -0.004 ? accent : ink3)
    }

    static func amount(_ value: Double) -> Color {
        value < 0 ? accent : (value > 0 ? positive : ink2)
    }
}

extension Font {
    /// The Windows build sets explicit pixel sizes (text-[13px], text-xs …); SF Pro stands in for Segoe UI.
    /// Follows the layout density (Settings → Compact scales like the Windows 15px root size).
    static func zen(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * ZenPersonalization.scale, weight: weight)
    }
}

/// Fine-line icon (lucide at stroke-width 1.5 in the Windows build) rendered with SF Symbols.
struct ZIcon: View {
    let name: String
    var size: CGFloat = 16
    var weight: Font.Weight = .light

    init(_ name: String, size: CGFloat = 16, weight: Font.Weight = .light) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size * 0.86, weight: weight))
            .frame(width: size, height: size)
    }
}

extension Color {
    /// A color that follows the system appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// Parses "#rrggbb" strings as stored in the ledger (group / account colors).
    init(hexString: String) {
        if let cached = HexColorCache.colors[hexString] {
            self = cached
            return
        }
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self.init(nsColor: NSColor(hex: UInt32(cleaned, radix: 16) ?? 0x7A746B))
        HexColorCache.colors[hexString] = self
    }
}

/// Group / account colors ("#rrggbb") are a small fixed set; reuse their Color values.
private enum HexColorCache {
    nonisolated(unsafe) static var colors: [String: Color] = [:]
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
