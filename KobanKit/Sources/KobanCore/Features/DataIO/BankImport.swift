import Foundation

enum BankFileFormat: String, CaseIterable, Sendable {
    case camt053
    case ofx
    case csv
    case spreadsheet
}

struct RawBankTransaction: Hashable, Sendable {
    var rowIndex: Int
    var date: String // YYYY-MM-DD
    var signedAmount: Double
    var currency: String?
    var externalId: String?
    var rawPayee: String
    var rawDescription: String
    var reference: String?
    var counterpartyIban: String?
    var categoryHint: String?
    var bankTxCode: String?
}

enum CategorizationConfidence: String, CaseIterable, Sendable {
    case rule
    case history
    case keyword
    case needsReview = "needs_review"
}

enum DuplicateStatus: String, CaseIterable, Sendable {
    case none
    case exactDuplicate = "exact_duplicate"
    case possibleDuplicate = "possible_duplicate"
}

enum BankProfileMatchSource: String, Sendable {
    case saved
    case builtin
    case auto
}

struct StagedBankTransaction: Identifiable, Hashable, Sendable {
    var id: String
    var raw: RawBankTransaction
    var included: Bool
    var date: String
    var monthKey: String
    var mode: LedgerMode
    var type: TransactionType
    var accountId: String?
    var categoryId: String?
    var description: String
    var rawDescription: String
    var amount: Double
    var client: String?
    var invoiceRef: String?
    var taxRate: Double
    var deductiblePct: Double
    var paymentMethod: String
    var externalId: String?
    var importFingerprint: String
    var confidence: CategorizationConfidence
    var matchReason: String
    var matchedRuleId: String?
    var duplicateStatus: DuplicateStatus
    var duplicateOfLabel: String?
    var isTransferCandidate: Bool
    var transferHint: String?
    var transferPeerId: String?
}

struct BankStatementParseResult: Sendable {
    var format: BankFileFormat
    var fileName: String
    var sheetName: String?
    var detectedAccountIban: String?
    var detectedCurrency: String?
    var rawRows: [[String]]?
    var headerRowIndex: Int?
    var headers: [String]?
    var delimiter: String?
    var matchedProfile: BankImportProfile?
    var matchedProfileSource: BankProfileMatchSource?
    var needsMappingReview: Bool
    var activeMapping: BankImportProfile?
    var rawTransactions: [RawBankTransaction]
    var warnings: [String]
    var rawText: String? = nil
    var selectedProfileId: String? = nil
}

enum BankImport {
    // MARK: - Text decoding & deterministic fingerprint

    static func decodeTextData(_ data: Data) -> String {
        SheetCSV.decode(data)
    }

    private static let fnvPrime64: UInt64 = 0x0000_0100_0000_01b3
    private static let fnvOffset1: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let fnvOffset2: UInt64 = 0x8422_2325_cbf2_9ce4

    private static func fnv1a64Hex(_ bytes: [UInt8], offsetBasis: UInt64) -> String {
        var h = offsetBasis
        for b in bytes {
            h ^= UInt64(b)
            h &*= fnvPrime64
        }
        return String(format: "%016llx", h)
    }

    /// Synchronous 128-bit FNV-1a fingerprint identical to TypeScript `computeImportFingerprint`.
    static func computeImportFingerprint(
        accountId: String?,
        date: String,
        signedAmount: Double,
        normalizedKey: String,
        occurrenceIndex: Int
    ) -> String {
        let signedCents = Int64((signedAmount * 100.0).rounded())
        let canonical = "\(accountId ?? "")|\(date)|\(signedCents)|\(normalizedKey)|\(occurrenceIndex)"
        let bytes = Array(canonical.utf8)
        let bytes2 = [UInt8(0x3a)] + bytes
        return fnv1a64Hex(bytes, offsetBasis: fnvOffset1) + fnv1a64Hex(bytes2, offsetBasis: fnvOffset2)
    }

    // MARK: - Merchant normalization

    private static let noisePhrases: [String] = [
        "pos purchase",
        "card purchase",
        "debit card",
        "credit card",
        "visapurchase",
        "mastercard",
        "debitkarte",
        "ec-direct",
        "maestro",
        "twint zahlung",
        "twint p2p",
        "twint",
        "sepa-lastschrift",
        "sepa lastschrift",
        "sepa-uberweisung",
        "sepa ueberweisung",
        "sepa credit transfer",
        "lastschrift",
        "gutschrift",
        "e-banking",
        "ebanking",
        "mobile banking",
        "kartenzahlung",
        "einkauf",
        "zahlung",
        "paiement",
        "achat",
        "beleg-nr",
        "karten-nr",
        "card no",
        "ref-nr",
    ]

    private static func regexReplace(_ text: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func regexFirstMatch(_ text: String, pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            let r = match.range(at: i)
            if r.location != NSNotFound, let sr = Range(r, in: text) {
                groups.append(String(text[sr]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    private static func regexMatches(_ text: String, pattern: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    static func normalizeMerchantText(_ raw: String) -> String {
        var s = raw
            .decomposedStringWithCanonicalMapping
            .unicodeScalars
            .filter { !$0.properties.isDiacritic }
            .map(String.init)
            .joined()
            .lowercased()

        s = regexReplace(s, pattern: #"\b(?:xxxx|x{4}|\*{2,4})[- ]?\d{2,4}\b"#, with: " ")
        s = regexReplace(s, pattern: #"\*\d{4}\b"#, with: " ")
        s = regexReplace(s, pattern: #"\b\d{1,2}[./-]\d{1,2}(?:[./-]\d{2,4})?\b"#, with: " ")
        s = regexReplace(s, pattern: #"\b\d{4}-\d{2}-\d{2}\b"#, with: " ")
        s = regexReplace(s, pattern: #"\b\d{2}:\d{2}(?::\d{2})?\b"#, with: " ")
        s = regexReplace(s, pattern: #"\b(?:ch|de|fr|it|at|gb|us)\d{2}[a-z0-9]{10,30}\b"#, with: " ")

        for phrase in noisePhrases {
            s = s.replacingOccurrences(of: phrase, with: " ")
        }

        s = regexReplace(s, pattern: #"\b(?:chf|eur|usd|gbp|jpy)\b"#, with: " ")
        s = regexReplace(s, pattern: #"\b\d{4,}\b"#, with: " ")
        s = regexReplace(s, pattern: #"[^a-z0-9]+"#, with: " ")
        s = regexReplace(s, pattern: #"\s+"#, with: " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func suggestRulePattern(rawPayee: String, rawDescription: String) -> String {
        let normPayee = normalizeMerchantText(rawPayee)
        let normDesc = normalizeMerchantText(rawDescription)
        let source = normPayee.isEmpty ? normDesc : normPayee
        if source.isEmpty {
            let fallback = rawPayee.isEmpty ? rawDescription : rawPayee
            return String(fallback.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        }
        let tokens = source.split(separator: " ").map(String.init).filter { tok in
            tok.count >= 2 && !tok.allSatisfy(\.isNumber)
        }
        if tokens.isEmpty { return String(source.prefix(24)) }
        return tokens.prefix(2).joined(separator: " ")
    }

    // MARK: - Date & Number Parsers

    private static func validYmd(year: Int, month: Int, day: Int) -> String? {
        guard year >= 1900, year <= 2100, month >= 1, month <= 12, day >= 1, day <= 31 else {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comp = DateComponents()
        comp.year = year
        comp.month = month
        comp.day = day
        guard let date = cal.date(from: comp) else { return nil }
        let check = cal.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func expandTwoDigitYear(_ yy: Int) -> Int {
        yy >= 70 ? 1900 + yy : 2000 + yy
    }

    static func inferDateFormatFromSamples(_ samples: [String]) -> BankDateFormat {
        var sawDot = false
        var sawSlash = false
        var sawIso = false
        var dmyEvidence = 0
        var mdyEvidence = 0

        for raw in samples {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            if regexMatches(s, pattern: #"^\d{4}-\d{2}-\d{2}"#) {
                sawIso = true
                continue
            }
            if let dot = regexFirstMatch(s, pattern: #"^(\d{1,2})\.(\d{1,2})\.(\d{2,4})"#) {
                sawDot = true
                if let a = Int(dot[1]), a > 12 { dmyEvidence += 1 }
                if let b = Int(dot[2]), b > 12 { mdyEvidence += 1 }
                continue
            }
            if let slash = regexFirstMatch(s, pattern: #"^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})"#) {
                sawSlash = true
                if let a = Int(slash[1]), a > 12 { dmyEvidence += 1 }
                if let b = Int(slash[2]), b > 12 { mdyEvidence += 1 }
            }
        }

        if sawIso { return .iso }
        if sawDot { return .chDot }
        if sawSlash { return mdyEvidence > dmyEvidence ? .usSlash : .euSlash }
        return .auto
    }

    static func parseBankDate(_ raw: String, format: BankDateFormat = .auto, fallbackDmy: Bool = true) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        // 5-digit Excel serial date string
        if s.count == 5, s.allSatisfy(\.isNumber), let serial = Int(s), serial >= 20000, serial <= 80000 {
            return XLSXReader.isoDate(fromSerial: Double(serial), date1904: false)
        }

        if let iso = regexFirstMatch(s, pattern: #"^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[T\s].*)?$"#) {
            if let y = Int(iso[1]), let m = Int(iso[2]), let d = Int(iso[3]) {
                return validYmd(year: y, month: m, day: d)
            }
        }

        if (format == .auto || format == .compact),
           let comp = regexFirstMatch(s, pattern: #"^(\d{4})(\d{2})(\d{2})(?:\d{4,6})?(?:\[.*\])?$"#) {
            if let y = Int(comp[1]), let m = Int(comp[2]), let d = Int(comp[3]) {
                return validYmd(year: y, month: m, day: d)
            }
        }

        if let sepMatch = regexFirstMatch(s, pattern: #"^(\d{1,2})([./-])(\d{1,2})\2(\d{2,4})(?:\s.*)?$"#) {
            guard let a = Int(sepMatch[1]),
                  let b = Int(sepMatch[3]),
                  var year = Int(sepMatch[4]) else { return nil }
            let sep = sepMatch[2]
            if year < 100 { year = expandTwoDigitYear(year) }

            if format == .usSlash {
                return validYmd(year: year, month: a, day: b) ?? validYmd(year: year, month: b, day: a)
            }
            if format == .chDot || format == .euSlash {
                return validYmd(year: year, month: b, day: a) ?? validYmd(year: year, month: a, day: b)
            }
            if sep == "." { return validYmd(year: year, month: b, day: a) }
            if a > 12 { return validYmd(year: year, month: b, day: a) }
            if b > 12 { return validYmd(year: year, month: a, day: b) }
            return fallbackDmy
                ? validYmd(year: year, month: b, day: a)
                : validYmd(year: year, month: a, day: b)
        }

        return nil
    }

    static func parseBankNumber(_ raw: String, decimalSep: BankDecimalSeparator = .auto) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }

        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasSuffix("-") && !s.hasPrefix("-") {
            negative = true
            s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        s = regexReplace(s, pattern: #"(?:CHF|EUR|USD|GBP|JPY|Fr\.?|€|\$|£)"#, with: "")
        s = regexReplace(s, pattern: #"[\s\u{00a0}\u{202f}'’`]"#, with: "")

        if s.hasPrefix("-") {
            negative.toggle()
            s = String(s.dropFirst())
        } else if s.hasPrefix("+") {
            s = String(s.dropFirst())
        }

        s = String(s.filter { ("0"..."9").contains($0) || $0 == "." || $0 == "," })
        if s.isEmpty { return nil }

        let hasDot = s.contains(".")
        let hasComma = s.contains(",")

        var normalized = s
        switch decimalSep {
        case .comma:
            normalized = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            if let lastDot = normalized.lastIndex(of: ".") {
                let prefix = String(normalized[..<lastDot]).replacingOccurrences(of: ".", with: "")
                normalized = prefix + String(normalized[lastDot...])
            }
        case .dot:
            normalized = s.replacingOccurrences(of: ",", with: "")
        case .auto:
            if hasDot && hasComma {
                if let lastDot = s.lastIndex(of: "."), let lastComma = s.lastIndex(of: ",") {
                    if lastComma > lastDot {
                        normalized = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                    } else {
                        normalized = s.replacingOccurrences(of: ",", with: "")
                    }
                }
            } else if hasComma {
                let commaCount = s.filter { $0 == "," }.count
                if commaCount == 1, let idx = s.firstIndex(of: ",") {
                    let afterComma = s[s.index(after: idx)...]
                    normalized = afterComma.count != 3
                        ? s.replacingOccurrences(of: ",", with: ".")
                        : s.replacingOccurrences(of: ",", with: "")
                } else {
                    normalized = s.replacingOccurrences(of: ",", with: "")
                }
            } else if hasDot {
                let dotCount = s.filter { $0 == "." }.count
                if dotCount > 1, let lastDot = s.lastIndex(of: ".") {
                    let afterLast = s[s.index(after: lastDot)...]
                    if afterLast.count <= 2 {
                        let prefix = String(s[..<lastDot]).replacingOccurrences(of: ".", with: "")
                        normalized = prefix + "." + String(afterLast)
                    } else {
                        normalized = s.replacingOccurrences(of: ".", with: "")
                    }
                }
            }
        }

        guard let parsed = Double(normalized), parsed.isFinite else { return nil }
        return negative ? -abs(parsed) : parsed
    }

    // MARK: - XML Helpers & ISO 20022 camt.053 / camt.052 / camt.054 Parser

    private static func unescapeXml(_ str: String) -> String {
        var out = str
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")

        if let decRe = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let matches = decRe.matches(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out)).reversed()
            for m in matches {
                if let r = Range(m.range, in: out),
                   let gr = Range(m.range(at: 1), in: out),
                   let code = UInt32(out[gr]),
                   let scalar = UnicodeScalar(code) {
                    out.replaceSubrange(r, with: String(scalar))
                }
            }
        }
        if let hexRe = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
            let matches = hexRe.matches(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out)).reversed()
            for m in matches {
                if let r = Range(m.range, in: out),
                   let gr = Range(m.range(at: 1), in: out),
                   let code = UInt32(out[gr], radix: 16),
                   let scalar = UnicodeScalar(code) {
                    out.replaceSubrange(r, with: String(scalar))
                }
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func stripXmlCommentsAndCdata(_ xml: String) -> String {
        var out = regexReplace(xml, pattern: #"<!--[\s\S]*?-->"#, with: "")
        if let re = try? NSRegularExpression(pattern: #"<!\[CDATA\[([\s\S]*?)\]\]>"#) {
            let matches = re.matches(in: out, range: NSRange(out.startIndex..<out.endIndex, in: out)).reversed()
            for m in matches {
                if let full = Range(m.range, in: out), let innerR = Range(m.range(at: 1), in: out) {
                    let escaped = String(out[innerR])
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                    out.replaceSubrange(full, with: escaped)
                }
            }
        }
        return out
    }

    private static func extractTagBlocks(_ xml: String, localName: String) -> [String] {
        let escapedTag = NSRegularExpression.escapedPattern(for: localName)
        guard let re = try? NSRegularExpression(pattern: "<(/?)(?:[A-Za-z0-9_-]+:)?\(escapedTag)(?=[\\s>/])([^>]*)>") else {
            return []
        }
        let range = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = re.matches(in: xml, range: range)
        var results: [String] = []
        var depth = 0
        var blockStart: String.Index? = nil

        for m in matches {
            let isClosing = Range(m.range(at: 1), in: xml).map { String(xml[$0]) == "/" } ?? false
            let attrs = Range(m.range(at: 2), in: xml).map { String(xml[$0]) } ?? ""
            let isSelfClosing = !isClosing && attrs.trimmingCharacters(in: .whitespaces).hasSuffix("/")
            guard let matchRange = Range(m.range, in: xml) else { continue }

            if !isClosing {
                if isSelfClosing { continue }
                if depth == 0 { blockStart = matchRange.upperBound }
                depth += 1
            } else if depth > 0 {
                depth -= 1
                if depth == 0, let start = blockStart {
                    results.append(String(xml[start..<matchRange.lowerBound]))
                    blockStart = nil
                }
            }
        }
        return results
    }

    private static func extractTagText(_ xml: String, localName: String) -> String {
        let blocks = extractTagBlocks(xml, localName: localName)
        guard let first = blocks.first else { return "" }
        let stripped = regexReplace(first, pattern: "<[^>]+>", with: " ")
        let collapsed = regexReplace(stripped, pattern: #"\s+"#, with: " ")
        return unescapeXml(collapsed.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func extractTagAttr(_ xml: String, localName: String, attrName: String) -> String {
        let t = NSRegularExpression.escapedPattern(for: localName)
        let a = NSRegularExpression.escapedPattern(for: attrName)
        let pat = "<(?:[A-Za-z0-9_-]+:)?\(t)\\b[^>]*\\b\(a)\\s*=\\s*[\"']([^\"']+)[\"']"
        if let match = regexFirstMatch(xml, pattern: pat, options: [.caseInsensitive]) {
            return unescapeXml(match[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ""
    }

    static func isCamtXml(_ text: String) -> Bool {
        let head = String(text.prefix(2000)).lowercased()
        return head.contains("camt.053")
            || head.contains("camt.052")
            || head.contains("camt.054")
            || head.contains("bktocstmrstmt")
            || (head.contains("<ntry>") && head.contains("<amt"))
    }

    static func parseCamtXml(_ xmlRaw: String, fileName: String) -> BankStatementParseResult {
        let cleanXml = stripXmlCommentsAndCdata(xmlRaw)
        var warnings: [String] = []

        let acctBlocks = extractTagBlocks(cleanXml, localName: "Acct")
        let detectedAccountIban: String? = acctBlocks.first.flatMap { blk in
            let iban = extractTagText(blk, localName: "IBAN")
            let othr = extractTagText(blk, localName: "Othr")
            let chosen = iban.isEmpty ? othr : iban
            return chosen.isEmpty ? nil : chosen
        }
        let detectedCurrency: String? = acctBlocks.first.flatMap { blk in
            let ccy = extractTagText(blk, localName: "Ccy")
            return ccy.isEmpty ? nil : ccy
        }

        let entries = extractTagBlocks(cleanXml, localName: "Ntry")
        var rawTransactions: [RawBankTransaction] = []
        var rowIndex = 0

        for entry in entries {
            let entryAmtStr = extractTagText(entry, localName: "Amt")
            let entryCcyAttr = extractTagAttr(entry, localName: "Amt", attrName: "Ccy")
            let entryCcy = entryCcyAttr.isEmpty ? (detectedCurrency ?? "") : entryCcyAttr
            let entryCdtDbt = extractTagText(entry, localName: "CdtDbtInd").uppercased()

            let bookgBlock = extractTagBlocks(entry, localName: "BookgDt").first ?? ""
            let valBlock = extractTagBlocks(entry, localName: "ValDt").first ?? ""
            let rawDateCandidates = [
                extractTagText(bookgBlock, localName: "Dt"),
                extractTagText(bookgBlock, localName: "DtTm"),
                extractTagText(valBlock, localName: "Dt"),
                extractTagText(valBlock, localName: "DtTm"),
            ]
            let rawDateStr = rawDateCandidates.first { !$0.isEmpty } ?? ""
            let bookingDate = parseBankDate(String(rawDateStr.prefix(10)), format: .iso) ?? ""

            let acctSvcr = extractTagText(entry, localName: "AcctSvcrRef")
            let entryRef = acctSvcr.isEmpty ? extractTagText(entry, localName: "NtryRef") : acctSvcr
            let addtlEntry = extractTagText(entry, localName: "AddtlNtryInf")

            let bkTxBlock = extractTagBlocks(entry, localName: "BkTxCd").first ?? ""
            let domnBlock = extractTagBlocks(bkTxBlock, localName: "Domn").first ?? ""
            let fmlyBlock = extractTagBlocks(domnBlock, localName: "Fmly").first ?? ""
            let bankTxCode = [
                extractTagText(domnBlock, localName: "Cd"),
                extractTagText(fmlyBlock, localName: "Cd"),
                extractTagText(fmlyBlock, localName: "SubFmlyCd"),
            ].filter { !$0.isEmpty }.joined(separator: "-")

            let txDetailsList = extractTagBlocks(entry, localName: "TxDtls")
            let batches = txDetailsList.isEmpty ? [entry] : txDetailsList

            for (bIdx, tx) in batches.enumerated() {
                let isBatchChild = !txDetailsList.isEmpty

                let amtDtls = extractTagBlocks(tx, localName: "AmtDtls").first ?? ""
                let txAmtBlock = extractTagBlocks(amtDtls, localName: "TxAmt").first ?? amtDtls
                let amtFromTxDtls = extractTagText(txAmtBlock, localName: "Amt")
                var txAmtStr = amtFromTxDtls.isEmpty ? extractTagText(tx, localName: "Amt") : amtFromTxDtls
                let ccyFromTxDtls = extractTagAttr(txAmtBlock, localName: "Amt", attrName: "Ccy")
                var txCcy = ccyFromTxDtls.isEmpty ? extractTagAttr(tx, localName: "Amt", attrName: "Ccy") : ccyFromTxDtls

                if txAmtStr.isEmpty && (!isBatchChild || txDetailsList.count == 1) {
                    txAmtStr = entryAmtStr
                    if txCcy.isEmpty { txCcy = entryCcy }
                }

                let numAmt = parseBankNumber(txAmtStr, decimalSep: .dot)
                if numAmt == nil || abs(numAmt ?? 0) < 0.0001 || bookingDate.isEmpty {
                    if bookingDate.isEmpty && numAmt != nil {
                        warnings.append("Skipped entry row \(rowIndex + 1) without a valid booking date.")
                    }
                    rowIndex += 1
                    continue
                }

                let rawCdtDbt = extractTagText(tx, localName: "CdtDbtInd").uppercased()
                let txCdtDbt = rawCdtDbt.isEmpty ? (entryCdtDbt.isEmpty ? "DBIT" : entryCdtDbt) : rawCdtDbt
                let signedAmount = txCdtDbt == "DBIT" ? -abs(numAmt!) : abs(numAmt!)

                let refsBlock = extractTagBlocks(tx, localName: "Refs").first ?? tx
                var extId = [
                    extractTagText(refsBlock, localName: "AcctSvcrRef"),
                    extractTagText(refsBlock, localName: "TxId"),
                    extractTagText(refsBlock, localName: "EndToEndId"),
                    extractTagText(refsBlock, localName: "InstrId"),
                ].first { !$0.isEmpty } ?? ""
                if extId == "NOTPROVIDED" { extId = "" }
                if extId.isEmpty && !entryRef.isEmpty {
                    extId = txDetailsList.count > 1 ? "\(entryRef)#\(bIdx + 1)" : entryRef
                }

                let rltdBlock = extractTagBlocks(tx, localName: "RltdPties").first ?? ""
                let dbtrBlock = extractTagBlocks(rltdBlock, localName: "Dbtr").first ?? ""
                let cdtrBlock = extractTagBlocks(rltdBlock, localName: "Cdtr").first ?? ""
                let dbtrAcct = extractTagBlocks(rltdBlock, localName: "DbtrAcct").first ?? ""
                let cdtrAcct = extractTagBlocks(rltdBlock, localName: "CdtrAcct").first ?? ""

                let dbtrName = extractTagText(dbtrBlock, localName: "Nm")
                let cdtrName = extractTagText(cdtrBlock, localName: "Nm")
                let dbtrIban = extractTagText(dbtrAcct, localName: "IBAN")
                let cdtrIban = extractTagText(cdtrAcct, localName: "IBAN")

                let rawPayee = txCdtDbt == "CRDT"
                    ? (dbtrName.isEmpty ? cdtrName : dbtrName)
                    : (cdtrName.isEmpty ? dbtrName : cdtrName)
                let counterpartyIban = txCdtDbt == "CRDT"
                    ? (dbtrIban.isEmpty ? cdtrIban : dbtrIban)
                    : (cdtrIban.isEmpty ? dbtrIban : cdtrIban)

                let rmtBlock = extractTagBlocks(tx, localName: "RmtInf").first ?? ""
                let ustrdList = extractTagBlocks(rmtBlock, localName: "Ustrd").map { blk in
                    unescapeXml(regexReplace(regexReplace(blk, pattern: "<[^>]+>", with: " "), pattern: #"\s+"#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines))
                }.filter { !$0.isEmpty }
                let structuredRef = extractTagText(rmtBlock, localName: "Ref")
                let addtlTx = extractTagText(tx, localName: "AddtlTxInf")

                var uniqueDesc: [String] = []
                for p in ([rawPayee] + ustrdList + [addtlTx, addtlEntry]) where !p.isEmpty && !uniqueDesc.contains(p) {
                    uniqueDesc.append(p)
                }
                let rawDescription = uniqueDesc.isEmpty ? "Bank Transaction" : uniqueDesc.joined(separator: " · ")

                rawTransactions.append(RawBankTransaction(
                    rowIndex: rowIndex,
                    date: bookingDate,
                    signedAmount: signedAmount,
                    currency: txCcy.isEmpty ? detectedCurrency : txCcy,
                    externalId: extId.isEmpty ? nil : extId,
                    rawPayee: rawPayee,
                    rawDescription: rawDescription,
                    reference: (!structuredRef.isEmpty ? structuredRef : (!extId.isEmpty ? extId : nil)),
                    counterpartyIban: counterpartyIban.isEmpty ? nil : counterpartyIban,
                    categoryHint: nil,
                    bankTxCode: bankTxCode.isEmpty ? nil : bankTxCode
                ))
                rowIndex += 1
            }
        }

        return BankStatementParseResult(
            format: .camt053,
            fileName: fileName,
            sheetName: nil,
            detectedAccountIban: detectedAccountIban,
            detectedCurrency: detectedCurrency,
            rawRows: nil,
            headerRowIndex: nil,
            headers: nil,
            delimiter: nil,
            matchedProfile: nil,
            matchedProfileSource: nil,
            needsMappingReview: false,
            activeMapping: nil,
            rawTransactions: rawTransactions,
            warnings: warnings
        )
    }

    // MARK: - OFX / QFX Parser

    static func isOfxContent(_ text: String) -> Bool {
        let head = String(text.prefix(1500)).uppercased()
        return head.contains("OFXHEADER:") || head.contains("<OFX>") || head.contains("<STMTTRN>")
    }

    private static func readOfxLeaf(_ block: String, tag: String) -> String {
        let t = NSRegularExpression.escapedPattern(for: tag)
        if let m = regexFirstMatch(block, pattern: "<\(t)>([^<]*)</\(t)>", options: [.caseInsensitive]) {
            return unescapeXml(m[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let m = regexFirstMatch(block, pattern: "<\(t)>([^<\\r\\n]+)", options: [.caseInsensitive]) {
            return unescapeXml(m[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ""
    }

    static func parseOfx(_ text: String, fileName: String) -> BankStatementParseResult {
        var warnings: [String] = []
        let ccy = readOfxLeaf(text, tag: "CURDEF")
        let acct = readOfxLeaf(text, tag: "ACCTID")
        let blocks = extractTagBlocks(text, localName: "STMTTRN")
        let rawBlocks: [String]
        if !blocks.isEmpty {
            rawBlocks = blocks
        } else {
            rawBlocks = text.components(separatedBy: "<STMTTRN>").dropFirst().map { chunk in
                chunk.components(separatedBy: "</BANKTRANLIST>").first ?? chunk
            }
        }

        var rawTransactions: [RawBankTransaction] = []
        for (idx, blk) in rawBlocks.enumerated() {
            let dt = parseBankDate(readOfxLeaf(blk, tag: "DTPOSTED"), format: .compact)
                ?? parseBankDate(readOfxLeaf(blk, tag: "DTUSER"), format: .auto)
            let amt = parseBankNumber(readOfxLeaf(blk, tag: "TRNAMT"), decimalSep: .dot)
            guard let dateStr = dt, let signedAmount = amt, abs(signedAmount) >= 0.0001 else {
                if dt == nil && amt != nil { warnings.append("Skipped OFX transaction \(idx + 1): invalid date.") }
                continue
            }
            let fitid = readOfxLeaf(blk, tag: "FITID")
            let name = readOfxLeaf(blk, tag: "NAME")
            let memo = readOfxLeaf(blk, tag: "MEMO")
            let trnType = readOfxLeaf(blk, tag: "TRNTYPE")
            let checkNum = readOfxLeaf(blk, tag: "CHECKNUM")

            var parts: [String] = []
            for p in [name, memo] where !p.isEmpty && !parts.contains(p) { parts.append(p) }
            let rawDesc = parts.isEmpty ? (trnType.isEmpty ? "OFX Transaction" : trnType) : parts.joined(separator: " · ")

            rawTransactions.append(RawBankTransaction(
                rowIndex: idx,
                date: dateStr,
                signedAmount: signedAmount,
                currency: ccy.isEmpty ? nil : ccy,
                externalId: fitid.isEmpty ? nil : fitid,
                rawPayee: name,
                rawDescription: rawDesc,
                reference: !checkNum.isEmpty ? checkNum : (!fitid.isEmpty ? fitid : nil),
                counterpartyIban: nil,
                categoryHint: nil,
                bankTxCode: trnType.isEmpty ? nil : trnType
            ))
        }

        return BankStatementParseResult(
            format: .ofx,
            fileName: fileName,
            sheetName: nil,
            detectedAccountIban: acct.isEmpty ? nil : acct,
            detectedCurrency: ccy.isEmpty ? nil : ccy,
            rawRows: nil,
            headerRowIndex: nil,
            headers: nil,
            delimiter: nil,
            matchedProfile: nil,
            matchedProfileSource: nil,
            needsMappingReview: false,
            activeMapping: nil,
            rawTransactions: rawTransactions,
            warnings: warnings
        )
    }

    // MARK: - CSV Matrix & Header Detection

    private static func countDelimiterOnLines(_ lines: [String], delim: String) -> (modeCols: Int, consistency: Int) {
        let delimChar = delim.first ?? ","
        var counts: [Int] = []
        for line in lines {
            var inQuotes = false
            var c = 0
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if ch == "\"" {
                    if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                        i += 1
                    } else {
                        inQuotes.toggle()
                    }
                } else if ch == delimChar && !inQuotes {
                    c += 1
                }
                i += 1
            }
            counts.append(c)
        }
        let positive = counts.filter { $0 >= 1 }
        if positive.isEmpty { return (0, 0) }
        var freq: [Int: Int] = [:]
        for n in positive { freq[n, default: 0] += 1 }
        return (freq.values.max() ?? 0, positive.count)
    }

    private static func sniffDelimiter(_ lines: [String], preferredDelimiter: String? = nil) -> String {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(45)
        guard let first = nonEmpty.first else { return preferredDelimiter ?? "," }
        let trimmedFirst = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFirst.lowercased().hasPrefix("sep="), trimmedFirst.count == 5 {
            return String(trimmedFirst.last!)
        }

        let candidates = [";", ",", "\t", "|"]
        var best = ";"
        var bestScore = -1.0

        for delim in candidates {
            let stats = countDelimiterOnLines(Array(nonEmpty), delim: delim)
            if stats.consistency == 0 { continue }
            var totalPositive = 0
            let delimChar = delim.first!
            for line in nonEmpty {
                var inQuotes = false
                var c = 0
                let chars = Array(line)
                var i = 0
                while i < chars.count {
                    let ch = chars[i]
                    if ch == "\"" {
                        if inQuotes && i + 1 < chars.count && chars[i + 1] == "\"" {
                            i += 1
                        } else {
                            inQuotes.toggle()
                        }
                    } else if ch == delimChar && !inQuotes {
                        c += 1
                    }
                    i += 1
                }
                if c >= 1 { totalPositive += c }
            }
            let avgCols = Double(totalPositive) / Double(stats.consistency)
            let prefBoost = preferredDelimiter == delim ? 2.0 : 0.0
            let score = Double(stats.modeCols * 10) + min(avgCols, 20.0) + prefBoost
            if score > bestScore {
                bestScore = score
                best = delim
            }
        }
        if let preferredDelimiter, candidates.contains(preferredDelimiter) {
            let stats = countDelimiterOnLines(Array(nonEmpty), delim: preferredDelimiter)
            if stats.consistency >= max(2, Int(Double(nonEmpty.count) * 0.4)) && best == preferredDelimiter {
                return preferredDelimiter
            }
        }
        return bestScore > 0 ? best : (preferredDelimiter ?? ",")
    }

    static func parseCsvToMatrix(_ rawText: String, preferredDelimiter: String? = nil) -> (rows: [[String]], delimiter: String) {
        let linesRaw = rawText.components(separatedBy: CharacterSet.newlines)
        var text = rawText
        var delimiter = sniffDelimiter(linesRaw, preferredDelimiter: preferredDelimiter)
        let firstTrimmed = (linesRaw.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if firstTrimmed.lowercased().hasPrefix("sep="), firstTrimmed.count == 5 {
            delimiter = String(firstTrimmed.last!)
            if let nl = text.rangeOfCharacter(from: .newlines) {
                text = String(text[nl.upperBound...])
            }
        }

        let delimChar = delimiter.first ?? ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let scalars = Array(text)
        var i = 0

        while i < scalars.count {
            let ch = scalars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < scalars.count && scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == delimChar {
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else if ch == "\r\n" || ch == "\n" || ch == "\r" {
                row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                if row.contains(where: { !$0.isEmpty }) {
                    rows.append(row)
                }
                row = []
                field = ""
            } else {
                field.append(ch)
            }
            i += 1
        }
        row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        if row.contains(where: { !$0.isEmpty }) {
            rows.append(row)
        }
        return (rows, delimiter)
    }

    static func normalizeHeaderKey(_ raw: String) -> String {
        let pre = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "ä", with: "ae")
            .replacingOccurrences(of: "ö", with: "oe")
            .replacingOccurrences(of: "ü", with: "ue")
            .replacingOccurrences(of: "ß", with: "ss")
        let stripped = pre
            .decomposedStringWithCanonicalMapping
            .unicodeScalars
            .filter { !$0.properties.isDiacritic }
            .map(String.init)
            .joined()
        return regexReplace(stripped, pattern: #"[^a-z0-9]+"#, with: "")
    }

    private static let dateHeaderHints = [
        "date", "datum", "buchungsdatum", "buchungstag", "buchung", "valuta", "valutadatum",
        "valutatag", "booking date", "value date", "trade date", "transaction date", "started date",
        "completed date", "posting date", "booked at", "created on", "abschlussdatum",
        "date de comptabilisation", "date de transaction", "data di conclusione", "data",
    ]
    private static let amountHeaderHints = [
        "amount", "betrag", "montant", "importo", "total", "wert",
        "credit/debit amount", "individual amount", "debit", "belastung", "lastschrift",
        "ausgabe", "addebito", "credit", "gutschrift", "eingang", "accredito",
        "balance", "saldo", "einzelbetrag",
    ]
    private static let textHeaderHints = [
        "description", "description1", "description 1", "beschreibung", "beschreibung1",
        "beschreibung 1", "descrizione", "descrizione1", "buchungstext", "verwendungszweck",
        "avisierungstext", "bewegungstext", "notification text", "activity type", "activity name",
        "umsatztyp", "mitteilung", "details", "text", "memo", "subject", "payee",
        "merchant", "empfänger", "empfaenger", "auftraggeber", "begünstigter", "beguenstigter",
        "zahlungspflichtig", "zahlungszweck", "counterparty", "partner name", "payment reference",
        "name", "kategorie", "category", "währung", "currency", "waehrung", "monnaie", "moneta",
        "iban", "reference", "referenz", "transaction no", "transaktions-nr", "referenznummer",
    ]

    static func detectHeaderRow(_ matrix: [[String]]) -> Int {
        let limit = min(40, matrix.count)
        var bestIdx = 0
        var bestScore = -1

        for r in 0..<limit {
            let row = matrix[r]
            if row.filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count < 2 { continue }

            var score = 0
            var dateHits = 0
            var amountHits = 0
            var textHits = 0

            for rawCell in row {
                let cell = rawCell.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let normCell = normalizeHeaderKey(rawCell)
                if cell.isEmpty || cell.count > 60 { continue }
                if regexMatches(cell, pattern: #"^[+-]?\d[\d.,'’\s]*$"#) { continue }
                if parseBankDate(cell, format: .auto) != nil { continue }

                if dateHeaderHints.contains(where: { cell == $0 || cell.contains($0) || normCell == normalizeHeaderKey($0) }) {
                    dateHits += 1
                    score += 5
                } else if amountHeaderHints.contains(where: { cell == $0 || cell.contains($0) || normCell == normalizeHeaderKey($0) }) {
                    amountHits += 1
                    score += 4
                } else if textHeaderHints.contains(where: { cell == $0 || cell.contains($0) || normCell == normalizeHeaderKey($0) }) {
                    textHits += 1
                    score += 3
                }
            }

            if dateHits > 0 && amountHits > 0 { score += 8 }
            if dateHits > 0 && textHits > 0 { score += 4 }

            if r + 1 < matrix.count && score > 0 {
                let nextRow = matrix[r + 1]
                let hasData = nextRow.contains {
                    parseBankDate($0, format: .auto) != nil || parseBankNumber($0, decimalSep: .auto) != nil
                }
                if hasData { score += 5 }
            }

            if score > bestScore {
                bestScore = score
                bestIdx = r
            }
        }
        return bestScore > 0 ? bestIdx : 0
    }

    static func makeUniqueHeaders(_ headerRow: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return headerRow.enumerated().map { idx, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "Column \(idx + 1)" : trimmed
            let count = seen[base] ?? 0
            seen[base] = count + 1
            return count == 0 ? base : "\(base) (\(count + 1))"
        }
    }

    private static func extractPreambleIban(matrix: [[String]], headerRowIndex: Int) -> String? {
        let end = min(matrix.count, max(0, headerRowIndex))
        for r in 0..<end {
            for cell in matrix[r] {
                let compact = regexReplace(cell, pattern: #"\s+"#, with: "").uppercased()
                if let m = regexFirstMatch(compact, pattern: #"\b([A-Z]{2}\d{2}[A-Z0-9]{11,30})\b"#) {
                    return m[1]
                }
            }
        }
        return nil
    }

    // MARK: - Built-in Bank Profiles

    static let builtinProfiles: [BankImportProfile] = [
        BankImportProfile(
            id: "builtin-koban", name: "Koban Transactions Export",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Date", "Type", "Category", "Description", "Amount"],
            delimiter: ",", dateColumn: "Date", dateFormat: .iso,
            amountMode: .signed, amountColumn: "Amount", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Description"],
            payeeColumn: nil, referenceColumn: "Invoice / Ref", currencyColumn: nil,
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-ubs-ch", name: "UBS Switzerland (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Abschlussdatum", "Beschreibung1", "Belastung", "Gutschrift"],
            delimiter: ";", dateColumn: "Abschlussdatum", dateFormat: .chDot,
            amountMode: .splitDebitCredit, amountColumn: nil, debitColumn: "Belastung", creditColumn: "Gutschrift",
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Beschreibung1", "Beschreibung2", "Beschreibung3"],
            payeeColumn: nil, referenceColumn: "Transaktions-Nr.", currencyColumn: "Währung",
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-postfinance-ch", name: "PostFinance Switzerland (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Datum", "Avisierungstext", "Gutschrift in CHF", "Lastschrift in CHF"],
            delimiter: ";", dateColumn: "Datum", dateFormat: .auto,
            amountMode: .splitDebitCredit, amountColumn: nil, debitColumn: "Lastschrift in CHF", creditColumn: "Gutschrift in CHF",
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Avisierungstext"],
            payeeColumn: nil, referenceColumn: nil, currencyColumn: nil,
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-zkb-ch", name: "ZKB Zürcher Kantonalbank (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Datum", "Buchungstext", "Belastung CHF", "Gutschrift CHF"],
            delimiter: ";", dateColumn: "Datum", dateFormat: .chDot,
            amountMode: .splitDebitCredit, amountColumn: nil, debitColumn: "Belastung CHF", creditColumn: "Gutschrift CHF",
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Buchungstext", "Zahlungszweck"],
            payeeColumn: nil, referenceColumn: "ZKB-Referenz", currencyColumn: nil,
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-raiffeisen-ch", name: "Raiffeisen Switzerland (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Booked At", "Text", "Credit/Debit Amount"],
            delimiter: ";", dateColumn: "Booked At", dateFormat: .auto,
            amountMode: .signed, amountColumn: "Credit/Debit Amount", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Text"],
            payeeColumn: nil, referenceColumn: nil, currencyColumn: nil,
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-neon-ch", name: "Neon Switzerland (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Date", "Amount", "Description", "Subject"],
            delimiter: ";", dateColumn: "Date", dateFormat: .iso,
            amountMode: .signed, amountColumn: "Amount", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Description", "Subject"],
            payeeColumn: nil, referenceColumn: nil, currencyColumn: nil,
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-yuh-ch", name: "Yuh Switzerland (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["DATE", "ACTIVITY TYPE", "ACTIVITY NAME", "DEBIT", "CREDIT"],
            delimiter: ";", dateColumn: "DATE", dateFormat: .auto,
            amountMode: .splitDebitCredit, amountColumn: nil, debitColumn: "DEBIT", creditColumn: "CREDIT",
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["ACTIVITY NAME", "ACTIVITY TYPE"],
            payeeColumn: nil, referenceColumn: nil, currencyColumn: "PAYMENT CURRENCY",
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-migros-ch", name: "Migros Bank (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Datum", "Buchungstext", "Mitteilung", "Betrag"],
            delimiter: ";", dateColumn: "Datum", dateFormat: .chDot,
            amountMode: .signed, amountColumn: "Betrag", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Buchungstext", "Mitteilung"],
            payeeColumn: nil, referenceColumn: "Referenznummer", currencyColumn: nil,
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-revolut", name: "Revolut (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Started Date", "Description", "Amount", "Currency"],
            delimiter: ",", dateColumn: "Completed Date", dateFormat: .iso,
            amountMode: .signed, amountColumn: "Amount", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Description"],
            payeeColumn: nil, referenceColumn: nil, currencyColumn: "Currency",
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-wise", name: "Wise (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["TransferWise ID", "Date", "Amount", "Description"],
            delimiter: ",", dateColumn: "Date", dateFormat: .auto,
            amountMode: .signed, amountColumn: "Amount", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Description", "Merchant", "Payee Name"],
            payeeColumn: nil, referenceColumn: "TransferWise ID", currencyColumn: "Currency",
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-n26", name: "N26 (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Booking Date", "Partner Name", "Payment Reference", "Amount (EUR)"],
            delimiter: ",", dateColumn: "Booking Date", dateFormat: .iso,
            amountMode: .signed, amountColumn: "Amount (EUR)", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .dot, descriptionColumns: ["Partner Name", "Payment Reference"],
            payeeColumn: "Partner Name", referenceColumn: nil, currencyColumn: nil,
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-dkb-de", name: "DKB / German SEPA (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Buchungsdatum", "Verwendungszweck", "Betrag (€)"],
            delimiter: ";", dateColumn: "Buchungsdatum", dateFormat: .chDot,
            amountMode: .signed, amountColumn: "Betrag (€)", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .comma, descriptionColumns: ["Zahlungsempfänger*in", "Verwendungszweck"],
            payeeColumn: "Zahlungsempfänger*in", referenceColumn: "Kundenreferenz", currencyColumn: nil,
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-ing-de", name: "ING Germany (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Buchung", "Auftraggeber/Empfänger", "Buchungstext", "Verwendungszweck", "Betrag"],
            delimiter: ";", dateColumn: "Buchung", dateFormat: .chDot,
            amountMode: .signed, amountColumn: "Betrag", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .comma, descriptionColumns: ["Auftraggeber/Empfänger", "Buchungstext", "Verwendungszweck"],
            payeeColumn: "Auftraggeber/Empfänger", referenceColumn: nil, currencyColumn: "Währung",
            skipRows: nil, updatedAt: "2026-01-01"
        ),
        BankImportProfile(
            id: "builtin-sparkasse-de", name: "Sparkasse / Volksbank (CSV)",
            accountId: nil, defaultMode: nil,
            headerFingerprint: ["Buchungstag", "Buchungstext", "Verwendungszweck", "Betrag"],
            delimiter: ";", dateColumn: "Buchungstag", dateFormat: .chDot,
            amountMode: .signed, amountColumn: "Betrag", debitColumn: nil, creditColumn: nil,
            invertSign: false, decimalSeparator: .comma, descriptionColumns: ["Begünstigter/Zahlungspflichtiger", "Buchungstext", "Verwendungszweck"],
            payeeColumn: "Begünstigter/Zahlungspflichtiger", referenceColumn: nil, currencyColumn: "Waehrung",
            skipRows: nil, updatedAt: "2026-01-01"
        ),
    ]

    private static let bankAlternateFingerprints: [String: [[String]]] = [
        "builtin-ubs-ch": [
            ["Trade date", "Description1", "Debit", "Credit"],
            ["Booking date", "Description1", "Debit", "Credit"],
            ["Buchungsdatum", "Beschreibung1", "Belastung", "Gutschrift"],
            ["Buchungstag", "Beschreibung1", "Belastung", "Gutschrift"],
            ["Date de transaction", "Description1", "Débit", "Crédit"],
            ["Data di conclusione", "Descrizione1", "Addebito", "Accredito"],
        ],
        "builtin-postfinance-ch": [
            ["Buchungsdatum", "Avisierungstext", "Gutschrift", "Lastschrift"],
            ["Datum", "Bewegungstext", "Gutschrift", "Lastschrift"],
            ["Booking date", "Notification text", "Credit", "Debit"],
        ],
        "builtin-zkb-ch": [
            ["Buchungsdatum", "Buchungstext", "Belastung", "Gutschrift"],
            ["Datum", "Buchungstext", "Betrag CHF"],
        ],
        "builtin-raiffeisen-ch": [
            ["Valuta", "Buchungstext", "Belastung", "Gutschrift"],
            ["Buchungsdatum", "Buchungstext", "Betrag"],
        ],
        "builtin-yuh-ch": [
            ["DATE", "ACTIVITY NAME", "AMOUNT"],
            ["Date", "Activity name", "Debit", "Credit"],
        ],
        "builtin-n26": [
            ["Booking Date", "Partner Name", "Payment Reference", "Amount (CHF)"],
        ],
        "builtin-dkb-de": [
            ["Buchungsdatum", "Verwendungszweck", "Betrag"],
            ["Buchungstag", "Verwendungszweck", "Betrag (EUR)"],
        ],
    ]

    private struct BankAliasDef {
        var date: [String] = []
        var amount: [String] = []
        var debit: [String] = []
        var credit: [String] = []
        var description: [String] = []
        var payee: [String] = []
        var reference: [String] = []
        var currency: [String] = []
    }

    private static let bankHeaderAliases: [String: BankAliasDef] = [
        "builtin-ubs-ch": BankAliasDef(
            date: ["Abschlussdatum", "Buchungstag", "Buchungsdatum", "Valutadatum", "Trade date", "Booking date", "Value date", "Date de transaction", "Date de comptabilisation", "Data di conclusione"],
            amount: ["Einzelbetrag", "Individual amount", "Amount", "Betrag"],
            debit: ["Belastung", "Debit", "Débit", "Addebito", "Ausgabe"],
            credit: ["Gutschrift", "Credit", "Crédit", "Accredito", "Eingang"],
            description: ["Beschreibung 1", "Beschreibung 2", "Beschreibung 3", "Beschreibung", "Description 1", "Description 2", "Description 3", "Description", "Descrizione 1", "Descrizione 2", "Descrizione 3", "Buchungstext", "Fussnoten", "Footnotes"],
            reference: ["Transaktions-Nr.", "Transaction no.", "No de transaction", "Referenz"],
            currency: ["Währung", "Waehrung", "Currency", "Monnaie", "Moneta"]
        ),
        "builtin-postfinance-ch": BankAliasDef(
            date: ["Datum", "Buchungsdatum", "Valuta", "Booking date", "Date"],
            debit: ["Lastschrift in CHF", "Lastschrift", "Belastung", "Debit", "Débit"],
            credit: ["Gutschrift in CHF", "Gutschrift", "Credit", "Crédit"],
            description: ["Avisierungstext", "Bewegungstext", "Notification text", "Texte de notification", "Buchungstext"],
            currency: ["Währung", "Waehrung", "Currency"]
        ),
        "builtin-zkb-ch": BankAliasDef(
            date: ["Datum", "Buchungsdatum", "Valuta"],
            amount: ["Betrag CHF", "Betrag"],
            debit: ["Belastung CHF", "Belastung", "Debit"],
            credit: ["Gutschrift CHF", "Gutschrift", "Credit"],
            description: ["Buchungstext", "Zahlungszweck", "Details"],
            reference: ["ZKB-Referenz", "Referenz"]
        ),
        "builtin-raiffeisen-ch": BankAliasDef(
            date: ["Booked At", "Valuta", "Buchungsdatum", "Datum"],
            amount: ["Credit/Debit Amount", "Betrag", "Amount"],
            debit: ["Belastung", "Debit"],
            credit: ["Gutschrift", "Credit"],
            description: ["Text", "Buchungstext", "Mitteilung"]
        ),
        "builtin-yuh-ch": BankAliasDef(
            date: ["DATE", "Date"],
            amount: ["AMOUNT", "Amount"],
            debit: ["DEBIT", "Debit"],
            credit: ["CREDIT", "Credit"],
            description: ["ACTIVITY NAME", "ACTIVITY TYPE", "Description", "COUNTERPARTY"],
            payee: ["COUNTERPARTY", "ACTIVITY NAME"],
            currency: ["PAYMENT CURRENCY", "TRANSACTION CURRENCY", "Currency"]
        ),
        "builtin-migros-ch": BankAliasDef(
            date: ["Datum", "Valuta", "Buchungsdatum"],
            amount: ["Betrag", "Amount"],
            description: ["Buchungstext", "Mitteilung", "Text"],
            reference: ["Referenznummer", "Referenz"],
            currency: ["Währung", "Waehrung", "Currency"]
        ),
        "builtin-revolut": BankAliasDef(
            date: ["Completed Date", "Started Date", "Date"],
            amount: ["Amount"],
            description: ["Description", "Reference"],
            currency: ["Currency"]
        ),
        "builtin-n26": BankAliasDef(
            date: ["Booking Date", "Value Date"],
            amount: ["Amount (EUR)", "Amount (CHF)", "Amount"],
            description: ["Partner Name", "Payment Reference", "Type"],
            payee: ["Partner Name"]
        ),
        "builtin-dkb-de": BankAliasDef(
            date: ["Buchungsdatum", "Buchungstag", "Wertstellung"],
            amount: ["Betrag (€)", "Betrag (EUR)", "Betrag"],
            description: ["Zahlungsempfänger*in", "Zahlungspflichtige*r", "Verwendungszweck", "Umsatztyp"],
            payee: ["Zahlungsempfänger*in"],
            reference: ["Kundenreferenz"]
        ),
        "builtin-ing-de": BankAliasDef(
            date: ["Buchung", "Valuta"],
            amount: ["Betrag"],
            description: ["Auftraggeber/Empfänger", "Buchungstext", "Verwendungszweck"],
            payee: ["Auftraggeber/Empfänger"],
            currency: ["Währung"]
        ),
        "builtin-sparkasse-de": BankAliasDef(
            date: ["Buchungstag", "Valutatag", "Buchungsdatum"],
            amount: ["Betrag"],
            description: ["Begünstigter/Zahlungspflichtiger", "Buchungstext", "Verwendungszweck"],
            payee: ["Begünstigter/Zahlungspflichtiger"],
            currency: ["Waehrung", "Währung", "Currency"]
        ),
    ]

    private static func scoreFingerprint(headers: [String], fingerprint: [String]) -> Double {
        if fingerprint.isEmpty { return 0 }
        let lowerHeaders = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let normHeaders = headers.map { normalizeHeaderKey($0) }
        var hits = 0
        for fp in fingerprint {
            let fpl = fp.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let fpn = normalizeHeaderKey(fp)
            if lowerHeaders.contains(where: { $0 == fpl || $0.contains(fpl) })
                || (!fpn.isEmpty && normHeaders.contains(where: { $0 == fpn || $0.contains(fpn) })) {
                hits += 1
            }
        }
        return Double(hits) / Double(fingerprint.count)
    }

    private static func findColumn(headers: [String], candidates: [String]) -> String? {
        let lower = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let norm = headers.map { normalizeHeaderKey($0) }
        for c in candidates {
            let cl = c.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if cl.isEmpty { continue }
            if let idx = lower.firstIndex(of: cl) { return headers[idx] }
        }
        for c in candidates {
            let cn = normalizeHeaderKey(c)
            if cn.isEmpty { continue }
            if let idx = norm.firstIndex(of: cn) { return headers[idx] }
        }
        for c in candidates {
            let cl = c.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if cl.count < 3 { continue }
            if let idx = lower.firstIndex(where: { $0.contains(cl) }) { return headers[idx] }
        }
        for c in candidates {
            let cn = normalizeHeaderKey(c)
            if cn.count < 4 { continue }
            if let idx = norm.firstIndex(where: { $0.contains(cn) }) { return headers[idx] }
        }
        return nil
    }

    private static func findAllMatchingColumns(headers: [String], candidates: [String]) -> [String] {
        var out: [String] = []
        let lower = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let norm = headers.map { normalizeHeaderKey($0) }
        for cand in candidates {
            let cl = cand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let idx = lower.firstIndex(of: cl) {
                if !out.contains(headers[idx]) { out.append(headers[idx]) }
                continue
            }
            let cn = normalizeHeaderKey(cand)
            if !cn.isEmpty, let idx = norm.firstIndex(of: cn) {
                if !out.contains(headers[idx]) { out.append(headers[idx]) }
            }
        }
        return out
    }

    private static func resolveProfileAgainstHeaders(
        _ profile: BankImportProfile,
        headers: [String],
        sampleRows: [[String]]
    ) -> (resolved: BankImportProfile, missingFields: [String]) {
        let aliases = bankHeaderAliases[profile.id]
        let resolvedDate = findColumn(headers: headers, candidates: [profile.dateColumn] + (aliases?.date ?? []))

        var amountMode = profile.amountMode
        let resolvedDebit = findColumn(headers: headers, candidates: (profile.debitColumn.map { [$0] } ?? []) + (aliases?.debit ?? []))
        let resolvedCredit = findColumn(headers: headers, candidates: (profile.creditColumn.map { [$0] } ?? []) + (aliases?.credit ?? []))
        let resolvedAmount = findColumn(headers: headers, candidates: (profile.amountColumn.map { [$0] } ?? []) + (aliases?.amount ?? []))

        if amountMode == .splitDebitCredit {
            if resolvedDebit == nil && resolvedCredit == nil && resolvedAmount != nil {
                amountMode = .signed
            }
        } else if resolvedAmount == nil && resolvedDebit != nil && resolvedCredit != nil {
            amountMode = .splitDebitCredit
        }

        let descCandidates = profile.descriptionColumns + (aliases?.description ?? [])
        var resolvedDesc = findAllMatchingColumns(headers: headers, candidates: descCandidates)
        if resolvedDesc.isEmpty {
            if let fb = findColumn(headers: headers, candidates: [
                "description", "buchungstext", "verwendungszweck", "avisierungstext",
                "beschreibung", "text", "memo", "details", "subject", "purpose",
            ]) {
                resolvedDesc = [fb]
            }
        }

        let resolvedPayee: String? = (profile.payeeColumn != nil || !(aliases?.payee.isEmpty ?? true))
            ? findColumn(headers: headers, candidates: (profile.payeeColumn.map { [$0] } ?? []) + (aliases?.payee ?? []))
            : nil
        let resolvedRef: String? = (profile.referenceColumn != nil || !(aliases?.reference.isEmpty ?? true))
            ? findColumn(headers: headers, candidates: (profile.referenceColumn.map { [$0] } ?? []) + (aliases?.reference ?? []))
            : nil
        let resolvedCcy: String? = (profile.currencyColumn != nil || !(aliases?.currency.isEmpty ?? true))
            ? findColumn(headers: headers, candidates: (profile.currencyColumn.map { [$0] } ?? []) + (aliases?.currency ?? []))
            : nil

        var resolvedDateFormat = profile.dateFormat
        if let rd = resolvedDate, let dIdx = headers.firstIndex(of: rd) {
            let dateSamples = sampleRows.map { dIdx < $0.count ? $0[dIdx] : "" }
            let inferred = inferDateFormatFromSamples(dateSamples)
            if inferred != .auto { resolvedDateFormat = inferred }
        }

        var resolvedDec = profile.decimalSeparator
        if let amtCol = resolvedAmount ?? resolvedDebit ?? resolvedCredit, let aIdx = headers.firstIndex(of: amtCol) {
            let amtSamples = sampleRows.map { aIdx < $0.count ? $0[aIdx] : "" }
            let hasComma = amtSamples.contains { regexMatches($0, pattern: #"\d+\.\d{3},\d{1,2}\b"#) || regexMatches($0.trimmingCharacters(in: .whitespaces), pattern: #",\d{2}$"#) }
            let hasDot = amtSamples.contains { regexMatches($0.trimmingCharacters(in: .whitespaces), pattern: #"\.\d{2}$"#) }
            if hasComma && !hasDot { resolvedDec = .comma }
            else if hasDot && !hasComma { resolvedDec = .dot }
        }

        var missing: [String] = []
        if resolvedDate == nil { missing.append("Date") }
        if amountMode == .splitDebitCredit && resolvedDebit == nil && resolvedCredit == nil {
            missing.append("Debit / Credit")
        } else if amountMode == .signed && resolvedAmount == nil {
            missing.append("Amount")
        }
        if resolvedDesc.isEmpty && resolvedPayee == nil {
            missing.append("Description")
        }

        var out = profile
        out.dateColumn = resolvedDate ?? headers.first ?? profile.dateColumn
        out.dateFormat = resolvedDateFormat
        out.amountMode = amountMode
        out.amountColumn = resolvedAmount
        out.debitColumn = resolvedDebit
        out.creditColumn = resolvedCredit
        out.decimalSeparator = resolvedDec
        out.descriptionColumns = resolvedDesc
        out.payeeColumn = resolvedPayee
        out.referenceColumn = resolvedRef
        out.currencyColumn = resolvedCcy
        return (out, missing)
    }

    private static func inferAutoProfile(
        headers: [String],
        sampleRows: [[String]],
        accountId: String?,
        delimiter: String?
    ) -> (profile: BankImportProfile, needsMappingReview: Bool) {
        let dateColumn = findColumn(headers: headers, candidates: [
            "date", "trade date", "booking date", "completed date", "transaction date", "posting date",
            "datum", "abschlussdatum", "buchungsdatum", "buchungstag", "buchung", "valuta",
        ]) ?? headers.first ?? ""
        let debitCol = findColumn(headers: headers, candidates: ["debit", "belastung", "lastschrift", "ausgabe", "withdrawal", "addebito", "débit"])
        let creditCol = findColumn(headers: headers, candidates: ["credit", "gutschrift", "eingang", "deposit", "accredito", "crédit"])
        let amountCol = findColumn(headers: headers, candidates: ["amount", "betrag", "montant", "importo", "einzelbetrag", "individual amount", "total", "value", "sum", "chf", "eur"])
        let splitCols = debitCol != nil && creditCol != nil && (amountCol == nil || regexMatches(amountCol ?? "", pattern: "einzelbetrag|individual"))

        let payeeCol = findColumn(headers: headers, candidates: ["payee", "merchant", "empfänger", "empfaenger", "auftraggeber", "partner", "counterparty", "name"])
        let descCol1 = findColumn(headers: headers, candidates: ["description 1", "description1", "beschreibung 1", "beschreibung1", "description", "buchungstext", "verwendungszweck", "avisierungstext", "beschreibung", "text", "memo", "details", "subject", "purpose"])
        let descCol2 = findColumn(headers: headers, candidates: ["description 2", "description2", "beschreibung 2", "beschreibung2"])
        let descCol3 = findColumn(headers: headers, candidates: ["description 3", "description3", "beschreibung 3", "beschreibung3"])
        var descCols: [String] = []
        for col in [descCol1, descCol2, descCol3, payeeCol].compactMap({ $0 }) where !descCols.contains(col) { descCols.append(col) }
        if descCols.isEmpty && headers.count > 2 { descCols.append(headers[1]) }

        let dateColIdx = headers.firstIndex(of: dateColumn) ?? -1
        let dateSamples = dateColIdx >= 0 ? sampleRows.map { dateColIdx < $0.count ? $0[dateColIdx] : "" } : []
        let inferredDateFmt = inferDateFormatFromSamples(dateSamples)

        let amtIdx = amountCol.flatMap { headers.firstIndex(of: $0) } ?? -1
        let amtSamples = amtIdx >= 0 ? sampleRows.map { amtIdx < $0.count ? $0[amtIdx] : "" } : []
        var inferredDec: BankDecimalSeparator = .auto
        if amtSamples.contains(where: { regexMatches($0, pattern: #"\d+\.\d{3},\d{1,2}\b"#) || regexMatches($0.trimmingCharacters(in: .whitespaces), pattern: #",\d{2}$"#) }) {
            if !amtSamples.contains(where: { regexMatches($0.trimmingCharacters(in: .whitespaces), pattern: #"\.\d{2}$"#) }) {
                inferredDec = .comma
            }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let todayStr = fmt.string(from: Date())

        let profile = BankImportProfile(
            id: "prof-auto-\(DataIOJS.nowMillis())",
            name: "Custom Mapping",
            accountId: accountId,
            defaultMode: nil,
            headerFingerprint: Array(headers.prefix(8)),
            delimiter: delimiter,
            dateColumn: dateColumn,
            dateFormat: inferredDateFmt,
            amountMode: splitCols ? .splitDebitCredit : .signed,
            amountColumn: amountCol,
            debitColumn: debitCol,
            creditColumn: creditCol,
            invertSign: false,
            decimalSeparator: inferredDec,
            descriptionColumns: descCols,
            payeeColumn: payeeCol,
            referenceColumn: findColumn(headers: headers, candidates: ["reference", "referenz", "transaktions-nr.", "transaction no.", "invoiceref", "invoice", "ref", "fitid"]),
            currencyColumn: findColumn(headers: headers, candidates: ["currency", "währung", "waehrung", "ccy"]),
            skipRows: nil,
            updatedAt: todayStr
        )

        return (profile, !headers.isEmpty)
    }

    static func matchOrInferCsvProfile(
        headers: [String],
        sampleRows: [[String]],
        savedProfiles: [BankImportProfile],
        accountId: String?,
        delimiter: String?,
        selectedProfileId: String? = nil
    ) -> (profile: BankImportProfile, source: BankProfileMatchSource, needsMappingReview: Bool, warnings: [String]) {
        if selectedProfileId == "custom" {
            let auto = inferAutoProfile(headers: headers, sampleRows: sampleRows, accountId: accountId, delimiter: delimiter)
            return (auto.profile, .auto, true, [])
        }

        if let selectedProfileId, !selectedProfileId.isEmpty, selectedProfileId != "auto" {
            if let saved = savedProfiles.first(where: { $0.id == selectedProfileId }) {
                let (resolved, missing) = resolveProfileAgainstHeaders(saved, headers: headers, sampleRows: sampleRows)
                let warnings = missing.isEmpty ? [] : ["Saved profile \"\(saved.name)\" could not auto-match column(s): \(missing.joined(separator: ", "))."]
                return (resolved, .saved, !missing.isEmpty, warnings)
            }
            if let builtin = builtinProfiles.first(where: { $0.id == selectedProfileId }) {
                let (resolved, missing) = resolveProfileAgainstHeaders(builtin, headers: headers, sampleRows: sampleRows)
                let warnings = missing.isEmpty ? [] : ["Selected bank preset \"\(builtin.name)\" could not auto-match column(s): \(missing.joined(separator: ", ")). Please verify the mapping."]
                return (resolved, .builtin, !missing.isEmpty, warnings)
            }
        }

        let orderedSaved = savedProfiles.sorted { lhs, rhs in
            let lScope = lhs.accountId == accountId ? 1 : 0
            let rScope = rhs.accountId == accountId ? 1 : 0
            return lScope > rScope
        }

        for prof in orderedSaved where scoreFingerprint(headers: headers, fingerprint: prof.headerFingerprint) >= 0.75 {
            let (resolved, missing) = resolveProfileAgainstHeaders(prof, headers: headers, sampleRows: sampleRows)
            let warnings = missing.isEmpty ? [] : ["Saved profile \"\(prof.name)\" could not auto-match column(s): \(missing.joined(separator: ", "))."]
            return (resolved, .saved, !missing.isEmpty, warnings)
        }

        for preset in builtinProfiles {
            let fps = [preset.headerFingerprint] + (bankAlternateFingerprints[preset.id] ?? [])
            if fps.contains(where: { scoreFingerprint(headers: headers, fingerprint: $0) >= 0.75 }) {
                let (resolved, missing) = resolveProfileAgainstHeaders(preset, headers: headers, sampleRows: sampleRows)
                let warnings = missing.isEmpty ? [] : ["Detected \"\(preset.name)\", but could not auto-match column(s): \(missing.joined(separator: ", ")). Please verify the mapping."]
                return (resolved, .builtin, !missing.isEmpty, warnings)
            }
        }

        let auto = inferAutoProfile(headers: headers, sampleRows: sampleRows, accountId: accountId, delimiter: delimiter)
        return (auto.profile, .auto, auto.needsMappingReview, [])
    }

    static func extractRawTransactions(
        matrix: [[String]],
        headerRowIndex: Int,
        profile: BankImportProfile,
        fallbackCurrency: String?
    ) -> (rawTransactions: [RawBankTransaction], warnings: [String]) {
        guard headerRowIndex >= 0, headerRowIndex < matrix.count else {
            return ([], ["No header row found."])
        }
        let headers = makeUniqueHeaders(matrix[headerRowIndex])
        let normHeaders = headers.map { normalizeHeaderKey($0) }
        func colIdx(_ name: String?) -> Int {
            guard let name, !name.isEmpty else { return -1 }
            if let exact = headers.firstIndex(of: name) { return exact }
            let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let lc = headers.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lower }) {
                return lc
            }
            let norm = normalizeHeaderKey(name)
            return norm.isEmpty ? -1 : (normHeaders.firstIndex(of: norm) ?? -1)
        }

        let dIdx = colIdx(profile.dateColumn)
        let aIdx = colIdx(profile.amountColumn)
        let debIdx = colIdx(profile.debitColumn)
        let crIdx = colIdx(profile.creditColumn)
        let payIdx = colIdx(profile.payeeColumn)
        let refIdx = colIdx(profile.referenceColumn)
        let ccyIdx = colIdx(profile.currencyColumn)
        let catHintIdx = headers.firstIndex { ["category", "kategorie", "subcategory"].contains($0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? -1
        let typeHintIdx = headers.firstIndex { ["type", "kind", "direction"].contains($0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? -1
        var descIndices: [Int] = []
        for idx in profile.descriptionColumns.map({ colIdx($0) }) where idx >= 0 && !descIndices.contains(idx) {
            descIndices.append(idx)
        }

        var out: [RawBankTransaction] = []
        for r in (headerRowIndex + 1)..<matrix.count {
            let row = matrix[r]
            if row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { continue }
            let rawDate = dIdx >= 0 && dIdx < row.count ? row[dIdx] : ""
            guard let isoDate = parseBankDate(rawDate, format: profile.dateFormat, fallbackDmy: true) else { continue }

            var signedAmt: Double? = nil
            if profile.amountMode == .splitDebitCredit {
                let deb = debIdx >= 0 && debIdx < row.count ? parseBankNumber(row[debIdx], decimalSep: profile.decimalSeparator) : nil
                let cr = crIdx >= 0 && crIdx < row.count ? parseBankNumber(row[crIdx], decimalSep: profile.decimalSeparator) : nil
                if let deb, abs(deb) >= 0.0001 {
                    signedAmt = -abs(deb)
                } else if let cr, abs(cr) >= 0.0001 {
                    signedAmt = abs(cr)
                } else if aIdx >= 0 && aIdx < row.count {
                    signedAmt = parseBankNumber(row[aIdx], decimalSep: profile.decimalSeparator)
                }
            } else if aIdx >= 0 && aIdx < row.count {
                signedAmt = parseBankNumber(row[aIdx], decimalSep: profile.decimalSeparator)
            }

            guard var amt = signedAmt, abs(amt) >= 0.0001 else { continue }
            if typeHintIdx >= 0 && typeHintIdx < row.count && amt > 0 {
                let tCell = row[typeHintIdx].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if tCell == "expense" { amt = -abs(amt) }
                else if tCell == "income" { amt = abs(amt) }
            }
            if profile.invertSign { amt = -amt }

            let rawPayee = payIdx >= 0 && payIdx < row.count ? row[payIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            var descParts: [String] = []
            for idx in descIndices where idx < row.count {
                let piece = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty && !descParts.contains(piece) { descParts.append(piece) }
            }
            let rawDescription = descParts.isEmpty ? (rawPayee.isEmpty ? "Imported Bank Entry" : rawPayee) : descParts.joined(separator: " · ")
            let ref = refIdx >= 0 && refIdx < row.count ? row[refIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let ccyRaw = ccyIdx >= 0 && ccyIdx < row.count ? row[ccyIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let catHint = catHintIdx >= 0 && catHintIdx < row.count ? row[catHintIdx].trimmingCharacters(in: .whitespacesAndNewlines) : ""

            out.append(RawBankTransaction(
                rowIndex: r,
                date: isoDate,
                signedAmount: amt,
                currency: ccyRaw.isEmpty ? fallbackCurrency : ccyRaw,
                externalId: (profile.id == "builtin-wise" && !ref.isEmpty) ? ref : nil,
                rawPayee: rawPayee,
                rawDescription: rawDescription,
                reference: ref.isEmpty ? nil : ref,
                counterpartyIban: nil,
                categoryHint: catHint.isEmpty ? nil : catHint,
                bankTxCode: nil
            ))
        }
        return (out, [])
    }

    private static func preferredDelimiterForSelection(
        _ selectedProfileId: String?,
        savedProfiles: [BankImportProfile]
    ) -> String? {
        guard let id = selectedProfileId, !id.isEmpty, id != "auto", id != "custom" else { return nil }
        return savedProfiles.first(where: { $0.id == id })?.delimiter
            ?? builtinProfiles.first(where: { $0.id == id })?.delimiter
    }

    private static func parseTabularRows(
        _ rows: [[String]],
        fileName: String,
        format: BankFileFormat,
        savedProfiles: [BankImportProfile],
        accountId: String?,
        fallbackCurrency: String?,
        selectedProfileId: String?,
        delimiter: String?,
        sheetName: String?,
        rawText: String?
    ) -> BankStatementParseResult {
        let headerIdx = detectHeaderRow(rows)
        let headers = headerIdx < rows.count ? makeUniqueHeaders(rows[headerIdx]) : []
        let samples = Array(rows.dropFirst(min(rows.count, headerIdx + 1)).prefix(15))
        let detectedIban = extractPreambleIban(matrix: rows, headerRowIndex: headerIdx)
        let matched = matchOrInferCsvProfile(
            headers: headers,
            sampleRows: samples,
            savedProfiles: savedProfiles,
            accountId: accountId,
            delimiter: delimiter,
            selectedProfileId: selectedProfileId
        )
        let extracted = extractRawTransactions(
            matrix: rows,
            headerRowIndex: headerIdx,
            profile: matched.profile,
            fallbackCurrency: fallbackCurrency
        )
        return BankStatementParseResult(
            format: format,
            fileName: fileName,
            sheetName: sheetName,
            detectedAccountIban: detectedIban,
            detectedCurrency: nil,
            rawRows: rows,
            headerRowIndex: headerIdx,
            headers: headers,
            delimiter: delimiter,
            matchedProfile: matched.profile,
            matchedProfileSource: matched.source,
            needsMappingReview: matched.needsMappingReview || extracted.rawTransactions.isEmpty,
            activeMapping: matched.profile,
            rawTransactions: extracted.rawTransactions,
            warnings: matched.warnings + extracted.warnings,
            rawText: rawText,
            selectedProfileId: selectedProfileId ?? "auto"
        )
    }

    static func parseStatement(
        data: Data,
        fileName: String,
        savedProfiles: [BankImportProfile] = [],
        accountId: String? = nil,
        fallbackCurrency: String? = nil,
        selectedProfileId: String? = nil
    ) throws -> BankStatementParseResult {
        let lower = fileName.lowercased()
        let isXlsx = lower.hasSuffix(".xlsx") || lower.hasSuffix(".xlsm") || data.starts(with: [0x50, 0x4B, 0x03, 0x04])
        let isBinaryXls = data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])

        if isBinaryXls {
            throw SpreadsheetError.legacyXLS
        }

        if !isXlsx {
            let text = decodeTextData(data)
            if lower.hasSuffix(".xml") || isCamtXml(text) {
                return parseCamtXml(text, fileName: fileName)
            }
            if lower.hasSuffix(".ofx") || lower.hasSuffix(".qfx") || isOfxContent(text) {
                return parseOfx(text, fileName: fileName)
            }

            let prefDelim = preferredDelimiterForSelection(selectedProfileId, savedProfiles: savedProfiles)
            let (rows, delim) = parseCsvToMatrix(text, preferredDelimiter: prefDelim)
            return parseTabularRows(
                rows,
                fileName: fileName,
                format: .csv,
                savedProfiles: savedProfiles,
                accountId: accountId,
                fallbackCurrency: fallbackCurrency,
                selectedProfileId: selectedProfileId,
                delimiter: delim,
                sheetName: nil,
                rawText: text
            )
        }

        let wb = try SpreadsheetReader.read(data: data, fileName: fileName)
        let sheet = wb.sheets.first(where: { $0.name.lowercased().contains("transaction") }) ?? wb.sheets.first
        let rows: [[String]] = (sheet?.rows ?? []).map { r in
            r.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { $0.contains { !$0.isEmpty } }

        return parseTabularRows(
            rows,
            fileName: fileName,
            format: .spreadsheet,
            savedProfiles: savedProfiles,
            accountId: accountId,
            fallbackCurrency: fallbackCurrency,
            selectedProfileId: selectedProfileId,
            delimiter: nil,
            sheetName: sheet?.name,
            rawText: nil
        )
    }

    static func reparseWithProfile(
        _ previous: BankStatementParseResult,
        selectedProfileId: String,
        savedProfiles: [BankImportProfile] = [],
        accountId: String? = nil,
        fallbackCurrency: String? = nil
    ) -> BankStatementParseResult {
        if previous.format == .camt053 || previous.format == .ofx {
            var copy = previous
            copy.selectedProfileId = selectedProfileId
            return copy
        }
        if previous.format == .csv, let rawText = previous.rawText {
            let prefDelim = preferredDelimiterForSelection(selectedProfileId, savedProfiles: savedProfiles)
            let (rows, delim) = parseCsvToMatrix(rawText, preferredDelimiter: prefDelim)
            return parseTabularRows(
                rows,
                fileName: previous.fileName,
                format: .csv,
                savedProfiles: savedProfiles,
                accountId: accountId,
                fallbackCurrency: fallbackCurrency ?? previous.detectedCurrency,
                selectedProfileId: selectedProfileId,
                delimiter: delim,
                sheetName: nil,
                rawText: rawText
            )
        }
        if let rawRows = previous.rawRows {
            return parseTabularRows(
                rawRows,
                fileName: previous.fileName,
                format: previous.format == .spreadsheet ? .spreadsheet : .csv,
                savedProfiles: savedProfiles,
                accountId: accountId,
                fallbackCurrency: fallbackCurrency ?? previous.detectedCurrency,
                selectedProfileId: selectedProfileId,
                delimiter: previous.delimiter,
                sheetName: previous.sheetName,
                rawText: previous.rawText
            )
        }
        var copy = previous
        copy.selectedProfileId = selectedProfileId
        return copy
    }

    // MARK: - Keyword Map & Rule Evaluation

    private struct KeywordRuleDef {
        let direction: TransactionType?
        let categoryIds: [String]
        let keywords: [String]
    }

    private static let keywordMap: [KeywordRuleDef] = [
        KeywordRuleDef(direction: .income, categoryIds: ["home-inc-wages", "biz-inc-retainers"],
                       keywords: ["salary", "lohn", "gehalt", "payroll", "salaire", "wages", "sala"]),
        KeywordRuleDef(direction: .income, categoryIds: ["home-inc-interest", "home-inc-dividends"],
                       keywords: ["dividend", "zins", "interest", "zinsen", "coupon"]),
        KeywordRuleDef(direction: .income, categoryIds: ["home-inc-refunds"],
                       keywords: ["refund", "rückerstattung", "ruckerstattung", "erstattung", "reimbursement", "remboursement"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-dl-groceries"],
                       keywords: ["migros", "coop", "aldi", "lidl", "denner", "volg", "manor food", "alnatura", "spar ", "edeka", "rewe", "carrefour", "whole foods", "trader joe", "supermarkt", "supermarket", "grocery", "lebensmittel"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-dl-coffee", "home-dl-dining", "biz-mkt-meals"],
                       keywords: ["starbucks", "cafe", "kaffee", "bakery", "backerei", "bäckerei", "restaurant", "bistro", "uber eats", "just eat", "deliveroo", "mcdo", "burger"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-tr-transit", "biz-trv-rail"],
                       keywords: ["sbb", "cff", "ffs", "zvv", "bvb", "vbz", "deutsche bahn", "bahn", "oebb", "obb", "uber", "taxi", "halbtax", "ga ", "train", "metro", "tram"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-tr-fuel"],
                       keywords: ["shell", "bp ", "avia", "agrola", "tamoil", "esso", "tankstelle", "benzin", "fuel", "gas station"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-tr-parking"],
                       keywords: ["parking", "parkhaus", "easypark", "seety", "toll", "maut"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-exp-rent", "biz-off-cowork"],
                       keywords: ["miete", "mietwohnung", "rent", "immobilien", "verwaltung", "hypothek", "mortgage", "loyer", "cowork"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-exp-elec"],
                       keywords: ["ewz", "ekz", "bkw", "romande energie", "strom", "electricity", "elektrizitat", "elektrizität"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-exp-internet", "home-exp-phone", "biz-off-internet"],
                       keywords: ["swisscom", "sunrise", "salt mobile", "galaxus mobile", "wingo", "telekom", "vodafone", "o2 ", "internet", "mobilfunk"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-hlth-ins"],
                       keywords: ["css", "helsana", "swica", "assura", "concordia", "sanitas", "atupri", "visana", "krankenkasse", "health insurance"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-hlth-doc", "home-hlth-meds"],
                       keywords: ["apotheke", "pharmacy", "amavita", "sun store", "coop vitality", "doctor", "arzt", "zahnarzt", "dentist", "spital", "clinic"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["biz-sw-ai", "home-sub-ai"],
                       keywords: ["openai", "chatgpt", "anthropic", "claude", "cursor", "copilot", "perplexity", "midjourney"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["biz-sw-cloud", "home-sub-icloud"],
                       keywords: ["aws", "amazon web", "cloudflare", "hetzner", "digitalocean", "vercel", "netlify", "linode", "github", "google cloud", "namecheap", "gandi", "hostpoint", "infomaniak"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["biz-sw-design"],
                       keywords: ["adobe", "figma", "jetbrains", "sketch", "canva", "notion", "linear"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-sub-spotify", "home-sub-netflix", "home-sub-youtube", "home-sub-apple", "home-sub-amazon"],
                       keywords: ["spotify", "netflix", "disney", "youtube", "apple.com/bill", "itunes", "amazon prime"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-ent-vacation", "biz-trv-flights"],
                       keywords: ["swiss intl", "lufthansa", "easyjet", "ryanair", "klm", "air france", "booking.com", "airbnb", "hotel"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-misc-bank", "biz-prof-bank", "biz-prof-fx"],
                       keywords: ["bank fee", "kontoführung", "kontofuhrung", "gebühr", "gebuhren", "fee", "frais", "stripe", "paypal fee"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-misc-atm"],
                       keywords: ["atm", "bancomat", "bargeldbezug", "cash withdrawal", "bezug"]),
        KeywordRuleDef(direction: .expense, categoryIds: ["home-obl-fedtax", "home-obl-statetax", "biz-tax-income", "biz-tax-vat"],
                       keywords: ["steueramt", "estv", "finanzamt", "tax office", "bundessteuer", "staatssteuer", "ahv", "ausgleichskasse"]),
    ]

    private static func matchesRule(
        _ rule: ImportRule,
        raw: RawBankTransaction,
        direction: TransactionType,
        accountId: String?
    ) -> Bool {
        guard rule.enabled else { return false }
        if let ruleAcc = rule.accountId, !ruleAcc.isEmpty, ruleAcc != accountId { return false }
        if let dir = rule.direction, dir != .any {
            if dir == .income && direction != .income { return false }
            if dir == .expense && direction != .expense { return false }
        }
        let absAmt = abs(raw.signedAmount)
        if let minA = rule.minAmount, absAmt < minA { return false }
        if let maxA = rule.maxAmount, absAmt > maxA { return false }

        let pat = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pat.isEmpty { return false }

        let haystack: String
        switch rule.matchField {
        case .payee:
            haystack = raw.rawPayee.isEmpty ? raw.rawDescription : raw.rawPayee
        case .description:
            haystack = raw.rawDescription
        case .iban:
            haystack = raw.counterpartyIban ?? ""
        case .any:
            haystack = "\(raw.rawPayee) \(raw.rawDescription) \(raw.counterpartyIban ?? "")".trimmingCharacters(in: .whitespaces)
        }

        let hayLower = haystack.lowercased()
        let patLower = pat.lowercased()

        switch rule.matchType {
        case .exact:
            return hayLower.trimmingCharacters(in: .whitespacesAndNewlines) == patLower
        case .startsWith:
            return hayLower.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(patLower)
        case .regex:
            return regexMatches(haystack, pattern: pat, options: [.caseInsensitive])
        case .contains:
            let normHay = normalizeMerchantText(haystack)
            let normPat = normalizeMerchantText(pat)
            return hayLower.contains(patLower) || (!normPat.isEmpty && normHay.contains(normPat))
        }
    }

    private static func isoDateToEpochDays(_ dateStr: String) -> Int {
        guard let m = regexFirstMatch(dateStr, pattern: #"^(\d{4})-(\d{2})-(\d{2})$"#),
              let y = Int(m[1]), let mo = Int(m[2]), let d = Int(m[3]) else { return 0 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comp = DateComponents()
        comp.year = y; comp.month = mo; comp.day = d
        guard let dt = cal.date(from: comp) else { return 0 }
        return Int(floor(dt.timeIntervalSince1970 / 86400.0))
    }

    // MARK: - Staging (Dedup + Transfers + 4-tier Categorization)

    static func stageBankTransactions(
        rawTransactions: [RawBankTransaction],
        state: LedgerState,
        targetMode: LedgerMode,
        accountId: String?,
        paymentMethodLabel: String? = nil,
        rulesOverride: [ImportRule]? = nil
    ) -> [StagedBankTransaction] {
        let existingTxs = state.transactions
        let catMap = Dictionary(state.categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let accMap = Dictionary(state.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let selectedAcc = accountId.flatMap { accMap[$0] }
        let effectivePaymentMethod = paymentMethodLabel ?? selectedAcc?.name ?? "Bank Import"

        var existingExternalIdToTxId: [String: String] = [:]
        var existingFingerprintToTxId: [String: String] = [:]
        for tx in existingTxs {
            if let ext = tx.externalId, !ext.isEmpty {
                let key = "\(tx.accountId ?? "")|\(ext)"
                if existingExternalIdToTxId[key] == nil { existingExternalIdToTxId[key] = tx.id }
            }
            if let fp = tx.importFingerprint, !fp.isEmpty, existingFingerprintToTxId[fp] == nil {
                existingFingerprintToTxId[fp] = tx.id
            }
        }

        // Payee history map
        var payeeHistory: [String: [String: Int]] = [:]
        for tx in existingTxs where catMap[tx.categoryId] != nil {
            let norm = normalizeMerchantText(tx.rawDescription ?? tx.description)
            if norm.count < 3 { continue }
            let histKey = "\(norm)|\(tx.type.rawValue)|\(tx.mode.rawValue)"
            var counts = payeeHistory[histKey] ?? [:]
            counts[tx.categoryId, default: 0] += 1
            payeeHistory[histKey] = counts
        }

        let orderedRules = (rulesOverride ?? state.importRules ?? []).sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.id < $1.id
        }

        let ownIbans = Set(
            state.accounts
                .map { ($0.accountNumberMasked ?? "").replacingOccurrences(of: " ", with: "").lowercased() }
                .filter { $0.count >= 6 }
        )

        struct PrecomputedRow {
            let raw: RawBankTransaction
            let baseDirection: TransactionType
            let normKey: String
            let fingerprint: String
            let exactDupLabel: String?
            let pairedTxId: String?
        }

        var dayOccurrenceCounter: [String: Int] = [:]
        var precomputed: [PrecomputedRow] = []
        var pairedExistingTxIds = Set<String>()

        for raw in rawTransactions {
            let baseDirection: TransactionType = raw.signedAmount >= 0 ? .income : .expense
            let payeeNorm = normalizeMerchantText(raw.rawPayee.isEmpty ? raw.rawDescription : raw.rawPayee)
            let descNorm = normalizeMerchantText(raw.rawDescription)
            let normKey = !payeeNorm.isEmpty ? payeeNorm : (!descNorm.isEmpty ? descNorm : "tx")
            let cents = Int64((raw.signedAmount * 100.0).rounded())
            let bucketKey = "\(accountId ?? "")|\(raw.date)|\(cents)|\(normKey)"
            let occIndex = dayOccurrenceCounter[bucketKey] ?? 0
            dayOccurrenceCounter[bucketKey] = occIndex + 1

            let fingerprint = computeImportFingerprint(
                accountId: accountId,
                date: raw.date,
                signedAmount: raw.signedAmount,
                normalizedKey: normKey,
                occurrenceIndex: occIndex
            )

            var exactDupLabel: String? = nil
            var pairedTxId: String? = nil
            if let ext = raw.externalId, !ext.isEmpty,
               let hitId = existingExternalIdToTxId["\(accountId ?? "")|\(ext)"] {
                pairedTxId = hitId
                exactDupLabel = "Ref \(ext)"
            } else if let hitId = existingFingerprintToTxId[fingerprint] {
                pairedTxId = hitId
                exactDupLabel = String(format: "%@ · %.2f", raw.date, abs(raw.signedAmount))
            }
            if let pid = pairedTxId { pairedExistingTxIds.insert(pid) }

            precomputed.append(PrecomputedRow(
                raw: raw,
                baseDirection: baseDirection,
                normKey: normKey,
                fingerprint: fingerprint,
                exactDupLabel: exactDupLabel,
                pairedTxId: pairedTxId
            ))
        }

        var staged: [StagedBankTransaction] = []

        for (i, item) in precomputed.enumerated() {
            let raw = item.raw
            let baseDirection = item.baseDirection
            let normKey = item.normKey
            let fingerprint = item.fingerprint

            // 1. Dedup
            var duplicateStatus: DuplicateStatus = .none
            var duplicateOfLabel: String? = nil
            if let exactLabel = item.exactDupLabel {
                duplicateStatus = .exactDuplicate
                duplicateOfLabel = exactLabel
            } else {
                let targetDays = isoDateToEpochDays(raw.date)
                if let fuzzy = existingTxs.first(where: { tx in
                    if pairedExistingTxIds.contains(tx.id) { return false }
                    if let accId = accountId, let txAcc = tx.accountId, txAcc != accId { return false }
                    if tx.type != baseDirection { return false }
                    if abs(tx.amount - abs(raw.signedAmount)) > 0.009 { return false }
                    return abs(isoDateToEpochDays(tx.date) - targetDays) <= 2
                }) {
                    duplicateStatus = .possibleDuplicate
                    duplicateOfLabel = "\(fuzzy.date) · \(fuzzy.description)"
                }
            }

            // 2. Cross-account internal transfer detection
            let targetDays = isoDateToEpochDays(raw.date)
            let oppositeType: TransactionType = baseDirection == .income ? .expense : .income
            let transferPeer = existingTxs.first { tx in
                if let accId = accountId, tx.accountId == accId { return false }
                if accountId == nil && tx.accountId == nil { return false }
                if tx.type != oppositeType { return false }
                if abs(tx.amount - abs(raw.signedAmount)) > 0.009 { return false }
                return abs(isoDateToEpochDays(tx.date) - targetDays) <= 3
            }

            let normCpIban = (raw.counterpartyIban ?? "").replacingOccurrences(of: " ", with: "").lowercased()
            let isOwnIban = !normCpIban.isEmpty && ownIbans.contains(normCpIban)
            let hasTransferKeyword = regexMatches(
                "\(raw.rawPayee) \(raw.rawDescription)",
                pattern: #"\b(internal transfer|eigenübertrag|eigenubertrag|umbuchung|kontoübertrag|virement interne|transfer from savings|transfer to savings)\b"#,
                options: [.caseInsensitive]
            )
            var isTransferCandidate = transferPeer != nil || isOwnIban || hasTransferKeyword
            var transferHint: String? = nil
            if let peer = transferPeer {
                let peerName = peer.accountId.flatMap { accMap[$0]?.name } ?? "another account"
                transferHint = "Matches \(peerName) on \(peer.date)"
            } else if isOwnIban || hasTransferKeyword {
                transferHint = "Internal transfer keyword or own IBAN"
            }

            // 3. Layered categorization cascade
            var resolvedMode = targetMode
            var resolvedCategory: CategoryItem? = nil
            var confidence: CategorizationConfidence = .needsReview
            var matchReason = "Needs manual category review"
            var matchedRuleId: String? = nil
            var cleanDescription = raw.rawPayee.isEmpty ? raw.rawDescription : raw.rawPayee
            var client: String? = nil
            var taxOverride: Double? = nil
            var dedOverride: Double? = nil

            if let hitRule = orderedRules.first(where: { matchesRule($0, raw: raw, direction: baseDirection, accountId: accountId) }) {
                if let sm = hitRule.setMode { resolvedMode = sm }
                if let cat = catMap[hitRule.setCategoryId] {
                    resolvedCategory = cat
                    resolvedMode = cat.mode
                }
                if let sp = hitRule.setPayee, !sp.isEmpty { cleanDescription = sp }
                if let sc = hitRule.setClient, !sc.isEmpty { client = sc }
                taxOverride = hitRule.setTaxRate
                dedOverride = hitRule.setDeductiblePct
                if hitRule.markAsTransfer == true {
                    isTransferCandidate = true
                    transferHint = transferHint ?? "Rule \"\(hitRule.name)\""
                }
                confidence = .rule
                matchedRuleId = hitRule.id
                matchReason = "Rule: \(hitRule.name.isEmpty ? hitRule.pattern : hitRule.name)"
            }

            if resolvedCategory == nil && normKey.count >= 3 {
                if let histCounts = payeeHistory["\(normKey)|\(baseDirection.rawValue)|\(resolvedMode.rawValue)"] {
                    let total = histCounts.values.reduce(0, +)
                    if let (topId, topCount) = histCounts.max(by: { $0.value < $1.value }),
                       total > 0,
                       topCount >= 2,
                       Double(topCount) / Double(total) >= 0.75,
                       let histCat = catMap[topId] {
                        resolvedCategory = histCat
                        confidence = .history
                        matchReason = "History (\(topCount)/\(total) past entries)"
                    }
                }
            }

            if resolvedCategory == nil, let hint = raw.categoryHint, !hint.isEmpty {
                let hintLower = hint.lowercased()
                if let byHint = state.categories.first(where: {
                    $0.mode == resolvedMode
                        && $0.name.lowercased() == hintLower
                        && (baseDirection == .income ? $0.kind == .income : $0.kind != .income)
                }) {
                    resolvedCategory = byHint
                    confidence = .keyword
                    matchReason = "Column category \"\(hint)\""
                }
            }

            if resolvedCategory == nil, let rawCode = raw.bankTxCode, !rawCode.isEmpty {
                let code = rawCode.uppercased()
                var codeTargets: [String] = []
                if code.contains("SALA") && baseDirection == .income {
                    codeTargets = ["home-inc-wages"]
                } else if code.contains("INTR") && baseDirection == .income {
                    codeTargets = ["home-inc-interest"]
                } else if code.contains("CHRG") && baseDirection == .expense {
                    codeTargets = [resolvedMode == .freelancer ? "biz-prof-bank" : "home-misc-bank"]
                } else if code.contains("TAXS") && baseDirection == .expense {
                    codeTargets = [resolvedMode == .freelancer ? "biz-tax-income" : "home-obl-fedtax"]
                }
                for cid in codeTargets {
                    if let c = state.categories.first(where: { $0.id == cid && $0.mode == resolvedMode }) {
                        resolvedCategory = c
                        confidence = .keyword
                        matchReason = "ISO Bank Code (\(rawCode))"
                        break
                    }
                }
            }

            if resolvedCategory == nil {
                let fullLower = " \(raw.rawPayee) \(raw.rawDescription) ".lowercased()
                for kwDef in keywordMap {
                    if let dir = kwDef.direction, dir != baseDirection { continue }
                    if !kwDef.keywords.contains(where: { fullLower.contains($0) }) { continue }
                    for cid in kwDef.categoryIds {
                        if let matchCat = state.categories.first(where: {
                            $0.id == cid
                                && $0.mode == resolvedMode
                                && (baseDirection == .income ? $0.kind == .income : $0.kind != .income)
                        }) {
                            resolvedCategory = matchCat
                            confidence = .keyword
                            matchReason = "Matched keyword"
                            break
                        }
                    }
                    if resolvedCategory != nil { break }
                }
            }

            let defaultTax = taxOverride ?? resolvedCategory?.taxRate ?? 0
            let defaultDed = dedOverride ?? resolvedCategory?.deductiblePct ?? (resolvedMode == .freelancer ? 100 : 0)

            staged.append(StagedBankTransaction(
                id: "staged-\(i)-\(fingerprint.prefix(8))",
                raw: raw,
                included: duplicateStatus == .none,
                date: raw.date,
                monthKey: String(raw.date.prefix(7)),
                mode: resolvedMode,
                type: baseDirection,
                accountId: accountId,
                categoryId: resolvedCategory?.id,
                description: String(cleanDescription.prefix(200)),
                rawDescription: raw.rawDescription,
                amount: abs(raw.signedAmount),
                client: client,
                invoiceRef: raw.reference,
                taxRate: defaultTax,
                deductiblePct: defaultDed,
                paymentMethod: effectivePaymentMethod,
                externalId: raw.externalId,
                importFingerprint: fingerprint,
                confidence: confidence,
                matchReason: matchReason,
                matchedRuleId: matchedRuleId,
                duplicateStatus: duplicateStatus,
                duplicateOfLabel: duplicateOfLabel,
                isTransferCandidate: isTransferCandidate,
                transferHint: transferHint,
                transferPeerId: transferPeer?.id
            ))
        }

        return staged
    }

    // MARK: - Commit to LedgerState

    static func applyStagedTransactionsToLedger(
        stagedRows: [StagedBankTransaction],
        currentState: LedgerState,
        savedProfile: BankImportProfile? = nil,
        savedRules: [ImportRule]? = nil,
        nowMs: Int64 = DataIOJS.nowMillis()
    ) -> LedgerState {
        let categories = currentState.categories
        let catMap = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var newTransactions: [TransactionItem] = []
        for (i, row) in stagedRows.enumerated() where row.included {
            let explicitCat = row.categoryId.flatMap { catMap[$0] }
            let chosenCat = explicitCat
                ?? categories.first(where: {
                    $0.mode == row.mode && (row.type == .income ? $0.kind == .income : $0.kind != .income)
                })
                ?? categories.first(where: { $0.mode == row.mode })
                ?? categories.first

            guard let cat = chosenCat else { continue }

            let trimmedDesc = row.description.trimmingCharacters(in: .whitespacesAndNewlines)
            newTransactions.append(TransactionItem(
                id: "tx-bank-\(nowMs)-\(i)-\(row.importFingerprint.prefix(6))",
                date: row.date,
                monthKey: row.monthKey,
                mode: cat.mode,
                type: row.type,
                categoryId: cat.id,
                accountId: row.accountId,
                description: trimmedDesc.isEmpty ? (row.rawDescription.isEmpty ? "Bank Transaction" : row.rawDescription) : trimmedDesc,
                amount: abs(row.amount),
                client: row.client,
                invoiceRef: row.invoiceRef,
                taxRate: row.taxRate,
                deductiblePct: row.deductiblePct,
                paymentMethod: row.paymentMethod.isEmpty ? "Bank Import" : row.paymentMethod,
                status: .cleared,
                notes: nil,
                recurringId: nil,
                externalId: row.externalId,
                importFingerprint: row.importFingerprint,
                rawDescription: (!row.rawDescription.isEmpty && row.rawDescription != row.description) ? row.rawDescription : nil,
                transferPeerId: row.transferPeerId
            ))
        }

        var nextProfiles = currentState.importProfiles ?? []
        if let prof = savedProfile {
            if let idx = nextProfiles.firstIndex(where: { $0.id == prof.id }) {
                nextProfiles[idx] = prof
            } else {
                nextProfiles.append(prof)
            }
        }

        let nextRules = savedRules ?? currentState.importRules ?? []
        var nextState = currentState
        nextState.settings.setupCompleted = true
        nextState.transactions = newTransactions + currentState.transactions
        nextState.importProfiles = nextProfiles
        nextState.importRules = nextRules
        return nextState
    }
}
