import Foundation

// Shared spreadsheet primitives for the Data I/O port (src/utils/exportImport.ts).
// The Windows build uses the `xlsx` (SheetJS) npm package; on macOS the workbook is
// written/read by XLSXWriter / XLSXReader and CSV by SheetCSV below.

/// One cell of an array-of-arrays sheet (`(string | number)[][]` in exportImport.ts).
enum SheetCell: Hashable, Sendable {
    case string(String)
    case number(Double)

    static let empty = SheetCell.string("")

    /// `String(cell ?? '')` in JavaScript.
    var text: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return DataIOJS.string(n)
        }
    }

    var isEmpty: Bool {
        if case .string(let s) = self { return s.isEmpty }
        return false
    }
}

extension SheetCell: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
}

/// A named sheet as array-of-arrays (rows padded to the sheet width, like
/// `sheet_to_json(ws, { header: 1, defval: '' })`).
struct SheetData: Hashable, Sendable {
    var name: String
    var rows: [[SheetCell]]
    /// Column widths in characters (`ws['!cols'] = [{ wch }]`), used by the writer only.
    var columnWidths: [Double] = []
}

struct WorkbookData: Hashable, Sendable {
    var sheets: [SheetData]
    var sheetNames: [String] { sheets.map(\.name) }
    func sheet(named name: String) -> SheetData? { sheets.first { $0.name == name } }
}

// MARK: - JavaScript number semantics

enum DataIOJS {
    /// `String(n)` for the values Koban produces (integers print without ".0").
    static func string(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
        if n == n.rounded(), abs(n) < 1e15 {
            return String(Int64(n))
        }
        return "\(n)"
    }

    /// `Number(n.toFixed(2))`.
    static func fixed2(_ n: Double) -> Double {
        let r = (n * 100).rounded() / 100
        return r == 0 ? 0 : r
    }

    /// `parseFloat(s)`: parses the longest numeric prefix after leading whitespace; nil = NaN.
    static func parseFloat(_ s: String) -> Double? {
        let chars = Array(s.drop(while: { $0.isWhitespace }))
        var i = 0
        var out = ""
        if i < chars.count, chars[i] == "+" || chars[i] == "-" { out.append(chars[i]); i += 1 }
        if chars.count - i >= 8, String(chars[i..<i + 8]) == "Infinity" {
            return out == "-" ? -.infinity : .infinity
        }
        var digits = 0
        while i < chars.count, chars[i].isASCII, chars[i].isNumber { out.append(chars[i]); i += 1; digits += 1 }
        if i < chars.count, chars[i] == "." {
            var frac = "."
            var j = i + 1
            var fracDigits = 0
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { frac.append(chars[j]); j += 1; fracDigits += 1 }
            if digits > 0 || fracDigits > 0 { out += frac; i = j; digits += fracDigits }
        }
        guard digits > 0 else { return nil }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var exp = "e"
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { exp.append(chars[j]); j += 1 }
            var expDigits = 0
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { exp.append(chars[j]); j += 1; expDigits += 1 }
            if expDigits > 0 { out += exp }
        }
        return Double(out)
    }

    /// `parseFloat(String(x).replace(/[^0-9.-]/g, ''))`
    static func parseStripped(_ s: String) -> Double? {
        parseFloat(String(s.filter { ("0"..."9").contains($0) || $0 == "." || $0 == "-" }))
    }

    /// `parseFloat(...) || 0`, but also 0 for ±Infinity: a non-finite number makes JSONEncoder
    /// throw, so a single imported "Infinity" would make every later vault save fail.
    static func orZero(_ v: Double?) -> Double {
        guard let v, v.isFinite else { return 0 }
        return v
    }

    static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - CSV

enum SheetCSV {
    /// escapeCsvCell in exportImport.ts. Text starting with `=`, `+`, `-`, `@`, tab or CR is run as
    /// a formula by Excel / Numbers / LibreOffice, so it gets a leading `'`; numbers are untouched.
    /// Quotes cells containing , " CR or LF.
    static func escape(_ cell: SheetCell) -> String {
        var s = cell.text
        if case .string = cell, let first = s.unicodeScalars.first,
           "=+-@\t\r".unicodeScalars.contains(first), !isPlainNumber(s) {
            s = "'" + s
        }
        if s.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// `-12.50`, `+3`, `-4,2`: numbers written as text, which must stay numeric in the export.
    private static func isPlainNumber(_ s: String) -> Bool {
        s.range(of: #"^[+-]?[0-9]+([.,][0-9]+)?$"#, options: .regularExpression) != nil
    }

    /// rowsToCsv: CRLF line endings, no trailing newline.
    static func write(_ rows: [[SheetCell]]) -> String {
        rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n")
    }

    /// write_text_file(add_bom: true) in lib.rs: UTF-8 with a BOM, so Excel detects the encoding.
    static func dataWithBOM(_ text: String) -> Data {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        return data
    }

    /// Decodes a CSV file (UTF-8 with or without BOM, UTF-16 with BOM, else Windows-1252).
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16) ?? ""
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Picks the delimiter like SheetJS' CSV sniffing: an explicit `sep=` line, else the most
    /// frequent of , ; TAB | in the first line (outside quotes).
    static func guessDelimiter(_ text: Substring) -> (Character, dropFirstLine: Bool) {
        if text.lowercased().hasPrefix("sep="), let c = text.dropFirst(4).first, c != "\n", c != "\r" {
            return (c, true)
        }
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0, "|": 0]
        var inQuotes = false
        for ch in text.prefix(4096) {
            if ch == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if ch == "\n" || ch == "\r" || ch == "\r\n" { break }
            if counts[ch] != nil { counts[ch]! += 1 }
        }
        let order: [Character] = [",", ";", "\t", "|"]
        var best: Character = ","
        for c in order where counts[c]! > counts[best]! { best = c }
        return (best, false)
    }

    /// RFC-4180 style parser ("" escapes, quoted newlines, CRLF/LF/CR rows). Rows are padded
    /// to the widest row; a final empty line is dropped.
    static func parse(_ raw: String) -> [[SheetCell]] {
        var text = Substring(raw)
        if text.first == "\u{FEFF}" { text = text.dropFirst() }
        let (delim, dropFirst) = guessDelimiter(text)
        if dropFirst {
            if let nl = text.firstIndex(where: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
                text = text[text.index(after: nl)...]
            } else { text = "" }
        }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var it = text.makeIterator()
        var pending: Character? = nil

        func endField() { row.append(field); field = ""; fieldStarted = false }
        func endRow() { endField(); rows.append(row); row = [] }

        while let ch = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = it.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else {
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"" where !fieldStarted || field.isEmpty:
                inQuotes = true; fieldStarted = true
            case delim:
                endField()
            case "\r\n", "\n", "\r":
                endRow()
            default:
                field.append(ch); fieldStarted = true
            }
        }
        if !field.isEmpty || !row.isEmpty || fieldStarted { endRow() }

        let width = rows.map(\.count).max() ?? 0
        return rows.map { r in
            r.map { SheetCell.string($0) } + Array(repeating: SheetCell.empty, count: width - r.count)
        }
    }
}
