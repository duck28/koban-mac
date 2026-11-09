import SwiftUI

/// Layout density + high-contrast amounts (data-density / data-high-contrast on <html> in App.tsx):
///
///     [data-density="compact"] { font-size: 0.9375rem }          → rem-based sizes shrink to 15/16
///     [data-high-contrast="true"] .tabular-nums { font-weight: 600 }
///
/// Shared views opt in with `.zenAmount()` (in place of `.monospacedDigit()` on figures) and
/// `ZenPersonalization.scaled(_:)` / `Font.zenScaled` for sizes that follow the density.
enum ZenPersonalization {
    nonisolated(unsafe) static var density: UiDensity = .comfortable
    nonisolated(unsafe) static var highContrastAmounts = false

    /// 1 for Comfortable, 0.9375 for Compact (root font-size 15px instead of 16px).
    static var scale: CGFloat { density == .compact ? 0.9375 : 1 }

    static func scaled(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.toNearestOrEven) }
}

extension Font {
    /// `.zen(size, weight)` that follows the layout density.
    static func zenScaled(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size * ZenPersonalization.scale, weight: weight)
    }
}

private struct ZenAmountModifier: ViewModifier {
    var weight: Font.Weight?
    func body(content: Content) -> some View {
        if ZenPersonalization.highContrastAmounts {
            content.monospacedDigit().fontWeight(.semibold)
        } else if let weight {
            content.monospacedDigit().fontWeight(weight)
        } else {
            content.monospacedDigit()
        }
    }
}

extension View {
    /// tabular-nums figure; semibold when "High-Contrast Balances" is on.
    func zenAmount(_ weight: Font.Weight? = nil) -> some View {
        modifier(ZenAmountModifier(weight: weight))
    }
}

extension LedgerStore {
    /// Pushes density / high-contrast settings to ZenPersonalization.
    func applyPersonalization() {
        ZenPersonalization.density = state.settings.density ?? .comfortable
        ZenPersonalization.highContrastAmounts = state.settings.highContrastAmounts ?? false
    }
}
