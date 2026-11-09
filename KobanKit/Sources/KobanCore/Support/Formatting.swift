import Foundation

// Port of formatCurrency / formatNumber from src/utils/calculations.ts
// (Swiss "de-CH" grouping; decimals only when the amount is not whole).

enum KobanFormat {
    // NumberFormatter is expensive to create; these run for every figure on screen, so the two
    // configurations are built once. (Formatting is only done on the main thread.)
    private static func makeFormatter(fractionDigits: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_CH")
        f.numberStyle = .decimal
        f.minimumFractionDigits = fractionDigits
        f.maximumFractionDigits = 2
        return f
    }
    private static let wholeFormatter = makeFormatter(fractionDigits: 0)
    private static let decimalFormatter = makeFormatter(fractionDigits: 2)

    static func number(_ amount: Double, alwaysDecimals: Bool = false) -> String {
        let isWhole = !alwaysDecimals && abs(amount - amount.rounded()) < 0.005
        let f = isWhole ? wholeFormatter : decimalFormatter
        return f.string(from: NSNumber(value: amount)) ?? String(amount)
    }

    static func currency(_ amount: Double, code: String = "CHF") -> String {
        "\(code) \(number(amount))"
    }
}
