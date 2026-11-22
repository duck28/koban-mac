import Foundation
import Security

struct PassphraseStrength: Equatable, Sendable {
    var length: Int
    var estimatedBits: Int
    /// 0 = too short (< min), 1 = weak, 2 = fair, 3 = good, 4 = strong
    var score: Int
    var meetsMinimum: Bool
    var label: String
}

/// Vault v2 passphrase evaluation, unbiased CSPRNG passphrase generation, and Crockford Base32 helpers.
enum AuthCrypto {
    static let minPassphraseLength = VaultCrypto.minPassphraseLength

    static func evaluatePassphraseStrength(_ raw: String, minimumLength: Int = VaultCrypto.minPassphraseLength) -> PassphraseStrength {
        let chars = Array(raw)
        let length = chars.count
        var hasLower = false, hasUpper = false, hasDigit = false, hasSymbol = false, hasExtended = false

        for ch in chars {
            if ch >= "a" && ch <= "z" { hasLower = true }
            else if ch >= "A" && ch <= "Z" { hasUpper = true }
            else if ch >= "0" && ch <= "9" { hasDigit = true }
            else if ch.asciiValue != nil { hasSymbol = true }
            else { hasExtended = true }
        }

        var pool = 0
        if hasLower { pool += 26 }
        if hasUpper { pool += 26 }
        if hasDigit { pool += 10 }
        if hasSymbol { pool += 33 }
        if hasExtended { pool += 64 }

        let uniqueRatio = length > 0 ? Double(Set(chars).count) / Double(length) : 0
        let bits: Int
        if length == 0 || pool == 0 {
            bits = 0
        } else {
            let factor = max(0.55, min(1.0, uniqueRatio + 0.18))
            bits = Int((Double(length) * log2(Double(pool)) * factor).rounded())
        }

        let meetsMin = length >= minimumLength
        let score: Int
        let label: String
        if !meetsMin {
            score = 0; label = "Too short (min \(minimumLength) chars)"
        } else if bits < 52 {
            score = 1; label = "Weak"
        } else if bits < 72 {
            score = 2; label = "Fair"
        } else if bits < 96 {
            score = 3; label = "Good"
        } else {
            score = 4; label = "Strong"
        }

        return PassphraseStrength(length: length, estimatedBits: bits, score: score, meetsMinimum: meetsMin, label: label)
    }

    private static let words: [String] = [
        "amber", "anchor", "apricot", "atlas", "autumn", "bamboo", "beacon", "breeze",
        "canyon", "cedar", "cinder", "cobalt", "compass", "copper", "coral", "cosmos",
        "crimson", "crystal", "cypress", "dawn", "delta", "dolphin", "dune", "echo",
        "eclipse", "emerald", "falcon", "fathom", "feather", "flint", "forest", "fossil",
        "frost", "galaxy", "garnet", "glacier", "granite", "harbor", "hazel", "horizon",
        "indigo", "island", "ivory", "jasper", "juniper", "kestrel", "lagoon", "lantern",
        "larch", "laurel", "linen", "lotus", "lunar", "maple", "marble", "meadow",
        "mercury", "mesa", "monarch", "mosaic", "nebula", "nectar", "nickel", "nimbus",
        "north", "oak", "obsidian", "ochre", "olive", "onyx", "opal", "orbit",
        "orchid", "osprey", "pebble", "pelican", "petal", "pine", "planet", "platinum",
        "plume", "polar", "prairie", "prism", "quartz", "quill", "raven", "redwood",
        "ridge", "ripple", "river", "saffron", "sapphire", "sequoia", "shadow", "sierra",
        "signal", "silver", "solstice", "spruce", "starlight", "stone", "summit", "sunlit",
        "tamarind", "terra", "thistle", "timber", "topaz", "torrent", "tundra", "umber",
        "valley", "velvet", "vermilion", "vesper", "violet", "walnut", "whisper", "willow",
        "winter", "wren", "zenith", "zephyr",
    ]

    private static func randomUnbiasedIndex(_ upperBound: Int) -> Int {
        precondition(upperBound > 1)
        let maxVal = UInt32.max - (UInt32.max % UInt32(upperBound))
        while true {
            var val: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &val) { ptr in
                SecRandomCopyBytes(kSecRandomDefault, 4, ptr.baseAddress!)
            }
            if status != errSecSuccess {
                return Int.random(in: 0..<upperBound)
            }
            if val < maxVal {
                return Int(val % UInt32(upperBound))
            }
        }
    }

    static func generateStrongPassphrase() -> String {
        var picked: [String] = []
        picked.reserveCapacity(5)
        for _ in 0..<5 {
            picked.append(words[randomUnbiasedIndex(words.count)])
        }
        let num = 10 + randomUnbiasedIndex(90)
        return "\(picked.joined(separator: "-"))-\(num)"
    }
}
