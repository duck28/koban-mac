import Foundation

/// Reads spreadsheet files into array-of-arrays sheets — the macOS replacement for
/// `XLSX.read(buffer)` + `sheet_to_json(..., { header: 1, defval: '' })`.
///
/// - .xlsx / .xlsm: unzipped with /usr/bin/unzip, then sharedStrings / styles / sheet XML are
///   parsed with XMLParser.
/// - .csv / .txt (and text files saved with an .xls extension, as many bank exports are): CSV.
/// - Legacy binary .xls (BIFF / OLE2): not supported, throws `SpreadsheetError.legacyXLS`.
enum SpreadsheetReader {
    static func read(url: URL) throws -> WorkbookData {
        let data = try Data(contentsOf: url)
        return try read(data: data, fileName: url.lastPathComponent)
    }

    static func read(data: Data, fileName: String) throws -> WorkbookData {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            return try XLSXReader.read(data: data)
        }
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) || (ext == "xls" && data.starts(with: [0x09, 0x08])) {
            throw SpreadsheetError.legacyXLS
        }
        if ext == "xlsx" || ext == "xlsm" {
            throw SpreadsheetError.invalidWorkbook("the file is not a ZIP-based Office Open XML workbook.")
        }
        let text = SheetCSV.decode(data)
        let base = (fileName as NSString).deletingPathExtension
        return WorkbookData(sheets: [SheetData(name: base.isEmpty ? "Sheet1" : String(base.prefix(31)), rows: SheetCSV.parse(text))])
    }
}

enum XLSXReader {
    static func read(data: Data) throws -> WorkbookData {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("koban-xlsx-read-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("x", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent("in.xlsx")
        try data.write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", "-o", file.path, "-d", dir.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw SpreadsheetError.unzipFailed(error.localizedDescription) }
        process.waitUntilExit()
        // unzip returns 1 for warnings (e.g. odd extra fields) — still usable.
        guard process.terminationStatus <= 1 else {
            let msg = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SpreadsheetError.unzipFailed(msg.isEmpty ? "unzip exited with \(process.terminationStatus)" : msg)
        }
        return try read(directory: dir)
    }

    static func read(directory dir: URL) throws -> WorkbookData {
        func load(_ path: String) -> Data? {
            let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
            // ZIP part names are case-insensitive in practice.
            let url = dir.appendingPathComponent(clean)
            if let d = try? Data(contentsOf: url) { return d }
            return nil
        }

        // Locate the workbook part through the package relationships.
        var workbookPath = "xl/workbook.xml"
        if let rels = load("_rels/.rels") {
            for rel in RelsParser.parse(rels) where rel.type.hasSuffix("/officeDocument") {
                workbookPath = rel.target.hasPrefix("/") ? String(rel.target.dropFirst()) : rel.target
            }
        }
        guard let workbookXML = load(workbookPath) else {
            throw SpreadsheetError.invalidWorkbook("xl/workbook.xml is missing.")
        }
        let baseDir = (workbookPath as NSString).deletingLastPathComponent
        let relsPath = (baseDir as NSString).appendingPathComponent("_rels/" + (workbookPath as NSString).lastPathComponent + ".rels")
        let wbRels = load(relsPath).map(RelsParser.parse) ?? []
        func resolve(_ target: String) -> String {
            if target.hasPrefix("/") { return String(target.dropFirst()) }
            return ((baseDir as NSString).appendingPathComponent(target) as NSString).standardizingPath
        }

        let wb = WorkbookParser.parse(workbookXML)
        let sharedStrings: [String] = {
            if let rel = wbRels.first(where: { $0.type.hasSuffix("/sharedStrings") }), let d = load(resolve(rel.target)) {
                return SharedStringsParser.parse(d)
            }
            return load(resolve("sharedStrings.xml")).map(SharedStringsParser.parse) ?? []
        }()
        let dateStyles: Set<Int> = {
            if let rel = wbRels.first(where: { $0.type.hasSuffix("/styles") }), let d = load(resolve(rel.target)) {
                return StylesParser.dateStyleIndexes(d)
            }
            return []
        }()

        var sheets: [SheetData] = []
        for (idx, entry) in wb.sheets.enumerated() {
            let target = wbRels.first(where: { $0.id == entry.relId })?.target ?? "worksheets/sheet\(idx + 1).xml"
            guard let xml = load(resolve(target)) else { continue }
            let rows = SheetParser.parse(xml, sharedStrings: sharedStrings, dateStyles: dateStyles, date1904: wb.date1904)
            sheets.append(SheetData(name: entry.name, rows: rows))
        }
        guard !sheets.isEmpty else { throw SpreadsheetError.invalidWorkbook("no worksheets were found.") }
        return WorkbookData(sheets: sheets)
    }

    /// Excel serial date → "YYYY-MM-DD" (1900 or 1904 date system).
    static func isoDate(fromSerial serial: Double, date1904: Bool) -> String {
        var days = serial.rounded(.down)
        if !date1904 && days < 61 { days += 1 } // Excel's fictitious 1900-02-29
        let base = date1904 ? DateComponents(year: 1904, month: 1, day: 1) : DateComponents(year: 1899, month: 12, day: 30)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let start = cal.date(from: base), let date = cal.date(byAdding: .day, value: Int(days), to: start) else {
            return DataIOJS.string(serial)
        }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - XML part parsers

private func localName(_ name: String) -> String {
    if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
    return name
}

private func attr(_ dict: [String: String], _ name: String) -> String? {
    if let v = dict[name] { return v }
    return dict.first(where: { localName($0.key) == name })?.value
}

private final class RelsParser: NSObject, XMLParserDelegate {
    struct Rel { var id: String; var type: String; var target: String }
    var rels: [Rel] = []

    static func parse(_ data: Data) -> [Rel] {
        let p = RelsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.rels
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard localName(elementName) == "Relationship" else { return }
        rels.append(Rel(id: attr(attributeDict, "Id") ?? "", type: attr(attributeDict, "Type") ?? "",
                        target: attr(attributeDict, "Target") ?? ""))
    }
}

private final class WorkbookParser: NSObject, XMLParserDelegate {
    struct Entry { var name: String; var relId: String }
    var sheets: [Entry] = []
    var date1904 = false

    static func parse(_ data: Data) -> WorkbookParser {
        let p = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "sheet":
            // r:id lives in the relationships namespace; match any prefix.
            let rid = attributeDict.first(where: { $0.key == "r:id" || ($0.key.hasSuffix(":id")) })?.value ?? ""
            sheets.append(Entry(name: attr(attributeDict, "name") ?? "Sheet\(sheets.count + 1)", relId: rid))
        case "workbookPr":
            let v = attr(attributeDict, "date1904")?.lowercased()
            date1904 = v == "1" || v == "true"
        default: break
        }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inSI = false
    private var inT = false
    private var phoneticDepth = 0

    static func parse(_ data: Data) -> [String] {
        let p = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "si": inSI = true; current = ""
        case "rPh": phoneticDepth += 1
        case "t": inT = inSI && phoneticDepth == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch localName(elementName) {
        case "si": strings.append(current); inSI = false
        case "rPh": phoneticDepth -= 1
        case "t": inT = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { current += string }
    }
}

private final class StylesParser: NSObject, XMLParserDelegate {
    private var customFormats: [Int: String] = [:]
    private var xfFormats: [Int] = []
    private var inCellXfs = false

    static func dateStyleIndexes(_ data: Data) -> Set<Int> {
        let p = StylesParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        var out = Set<Int>()
        for (idx, fmt) in p.xfFormats.enumerated() where p.isDateFormat(fmt) { out.insert(idx) }
        return out
    }

    private func isDateFormat(_ id: Int) -> Bool {
        if (14...22).contains(id) || (45...47).contains(id) || (27...36).contains(id) || (50...58).contains(id) { return true }
        guard let code = customFormats[id] else { return false }
        // Strip quoted literals, escapes and [colour]/[locale] sections, then look for date tokens.
        var cleaned = ""
        var inQuote = false
        var inBracket = false
        var skipNext = false
        for ch in code {
            if skipNext { skipNext = false; continue }
            if ch == "\\" { skipNext = true; continue }
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { continue }
            if ch == "[" { inBracket = true; continue }
            if ch == "]" { inBracket = false; continue }
            if inBracket { continue }
            cleaned.append(ch)
        }
        let lower = cleaned.lowercased()
        return lower.contains("d") || lower.contains("y") || (lower.contains("m") && !lower.contains("0"))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "numFmt":
            if let id = attr(attributeDict, "numFmtId").flatMap(Int.init), let code = attr(attributeDict, "formatCode") {
                customFormats[id] = code
            }
        case "cellXfs": inCellXfs = true
        case "xf" where inCellXfs:
            xfFormats.append(attr(attributeDict, "numFmtId").flatMap(Int.init) ?? 0)
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if localName(elementName) == "cellXfs" { inCellXfs = false }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let dateStyles: Set<Int>
    private let date1904: Bool
    private var cells: [Int: [Int: SheetCell]] = [:]
    private var maxCol = -1
    private var maxRow = -1

    private var rowIndex = -1
    private var colIndex = -1
    private var cellType = "n"
    private var cellStyle = 0
    private var value = ""
    private var inlineText = ""
    private var inV = false
    private var inIS = false
    private var inT = false
    private var phoneticDepth = 0
    private var inCell = false

    init(sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.date1904 = date1904
    }

    static func parse(_ data: Data, sharedStrings: [String], dateStyles: Set<Int>, date1904: Bool) -> [[SheetCell]] {
        let p = SheetParser(sharedStrings: sharedStrings, dateStyles: dateStyles, date1904: date1904)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        guard p.maxRow >= 0, p.maxCol >= 0 else { return [] }
        var rows: [[SheetCell]] = []
        rows.reserveCapacity(p.maxRow + 1)
        for r in 0...p.maxRow {
            var row = Array(repeating: SheetCell.empty, count: p.maxCol + 1)
            if let rc = p.cells[r] { for (c, v) in rc { row[c] = v } }
            rows.append(row)
        }
        return rows
    }

    static func decodeRef(_ ref: String) -> (row: Int, col: Int)? {
        var col = 0
        var rowDigits = ""
        var sawLetter = false
        for ch in ref.uppercased() {
            if ch == "$" { continue }
            if let a = ch.asciiValue, a >= 65, a <= 90, rowDigits.isEmpty {
                col = col * 26 + Int(a - 64); sawLetter = true
            } else if ch.isNumber {
                rowDigits.append(ch)
            }
        }
        guard sawLetter, let r = Int(rowDigits), r > 0 else { return nil }
        return (r - 1, col - 1)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch localName(elementName) {
        case "dimension":
            // SheetJS honours the declared range (trailing blank rows/cols included).
            if let ref = attr(attributeDict, "ref"), let last = ref.split(separator: ":").last,
               let d = SheetParser.decodeRef(String(last)), d.row < 100_000, d.col < 1_000 {
                maxRow = max(maxRow, d.row)
                maxCol = max(maxCol, d.col)
            }
        case "row":
            if let r = attr(attributeDict, "r").flatMap(Int.init) { rowIndex = r - 1 } else { rowIndex += 1 }
            colIndex = -1
        case "c":
            inCell = true
            if let ref = attr(attributeDict, "r"), let d = SheetParser.decodeRef(ref) {
                if rowIndex < 0 { rowIndex = d.row }
                colIndex = d.col
                rowIndex = d.row
            } else {
                colIndex += 1
                if rowIndex < 0 { rowIndex = 0 }
            }
            cellType = attr(attributeDict, "t") ?? "n"
            cellStyle = attr(attributeDict, "s").flatMap(Int.init) ?? 0
            value = ""
            inlineText = ""
        case "v": inV = inCell
        case "is": inIS = inCell
        case "rPh": phoneticDepth += 1
        case "t": inT = inIS && phoneticDepth == 0
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch localName(elementName) {
        case "v": inV = false
        case "is": inIS = false
        case "rPh": phoneticDepth -= 1
        case "t": inT = false
        case "c":
            inCell = false
            guard rowIndex >= 0, colIndex >= 0 else { return }
            let cell: SheetCell?
            switch cellType {
            case "s":
                if let i = Int(value.trimmingCharacters(in: .whitespaces)), i >= 0, i < sharedStrings.count {
                    cell = .string(sharedStrings[i])
                } else { cell = nil }
            case "inlineStr":
                cell = .string(inlineText)
            case "str", "e":
                cell = value.isEmpty ? nil : .string(value)
            case "b":
                cell = value.isEmpty ? nil : .string(value == "1" ? "true" : "false")
            case "d":
                cell = value.isEmpty ? nil : .string(String(value.prefix(10)))
            default:
                if let n = Double(value.trimmingCharacters(in: .whitespaces)) {
                    cell = dateStyles.contains(cellStyle) ? .string(XLSXReader.isoDate(fromSerial: n, date1904: date1904)) : .number(n)
                } else { cell = nil }
            }
            if let cell {
                cells[rowIndex, default: [:]][colIndex] = cell
                maxRow = max(maxRow, rowIndex)
                maxCol = max(maxCol, colIndex)
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inV { value += string } else if inT { inlineText += string }
    }
}
