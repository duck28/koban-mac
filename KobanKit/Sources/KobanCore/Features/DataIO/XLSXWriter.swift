import Foundation

enum SpreadsheetError: Error, LocalizedError, Equatable {
    case zipFailed(String)
    case unzipFailed(String)
    case invalidWorkbook(String)
    case legacyXLS
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .zipFailed(let m): return "Could not write the Excel workbook: \(m)"
        case .unzipFailed(let m): return "Could not open the Excel workbook: \(m)"
        case .invalidWorkbook(let m): return "The Excel workbook is invalid: \(m)"
        case .legacyXLS:
            return "Legacy Excel 97–2003 (.xls) workbooks can't be read on macOS. Open the file in Excel or Numbers, save it as .xlsx or .csv, and import it again."
        case .unsupported(let m): return m
        }
    }
}

/// Minimal Office Open XML (.xlsx) writer — replaces `XLSX.utils.aoa_to_sheet` +
/// `XLSX.write(wb, { bookType: 'xlsx' })`. Writes the package parts into a temporary folder
/// and zips them with /usr/bin/zip.
enum XLSXWriter {
    static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // XML 1.0 forbids most C0 control characters.
                if scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// "A", "B", … "Z", "AA" …
    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// Excel sheet names: max 31 chars, none of : \ / ? * [ ].
    static func sanitizeSheetName(_ name: String) -> String {
        let cleaned = String(name.map { ":\\/?*[]".contains($0) ? "_" : $0 })
        return String(cleaned.prefix(31))
    }

    /// Builds every part of the package as (path, xml) pairs.
    static func parts(for workbook: WorkbookData, created: Date = Date()) -> [(String, String)] {
        var sharedStrings: [String] = []
        var sharedIndex: [String: Int] = [:]
        var stringRefCount = 0
        func sst(_ s: String) -> Int {
            stringRefCount += 1
            if let i = sharedIndex[s] { return i }
            sharedStrings.append(s)
            sharedIndex[s] = sharedStrings.count - 1
            return sharedStrings.count - 1
        }

        var sheetXMLs: [String] = []
        for sheet in workbook.sheets {
            let width = sheet.rows.map(\.count).max() ?? 0
            let height = sheet.rows.count
            let ref = width > 0 && height > 0 ? "A1:\(columnName(width - 1))\(height)" : "A1"
            var xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="\(ref)"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/>
            """
            if !sheet.columnWidths.isEmpty {
                xml += "<cols>"
                for (i, w) in sheet.columnWidths.enumerated() {
                    xml += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(DataIOJS.string(w + 0.7109375))\" customWidth=\"1\"/>"
                }
                xml += "</cols>"
            }
            xml += "<sheetData>"
            for (r, row) in sheet.rows.enumerated() {
                var cells = ""
                for (c, cell) in row.enumerated() {
                    let addr = "\(columnName(c))\(r + 1)"
                    switch cell {
                    case .number(let n) where n.isFinite:
                        cells += "<c r=\"\(addr)\"><v>\(DataIOJS.string(n))</v></c>"
                    case .number:
                        continue
                    case .string(let s):
                        if s.isEmpty { continue }
                        cells += "<c r=\"\(addr)\" t=\"s\"><v>\(sst(s))</v></c>"
                    }
                }
                xml += "<row r=\"\(r + 1)\">\(cells)</row>"
            }
            xml += "</sheetData><pageMargins left=\"0.7\" right=\"0.7\" top=\"0.75\" bottom=\"0.75\" header=\"0.3\" footer=\"0.3\"/></worksheet>"
            sheetXMLs.append(xml)
        }

        let names = uniqueSheetNames(workbook.sheets.map(\.name))
        var parts: [(String, String)] = []

        var contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        """
        for i in sheetXMLs.indices {
            contentTypes += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        contentTypes += """
        <Override PartName="/xl/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
        """
        parts.append(("[Content_Types].xml", contentTypes))

        parts.append(("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let stamp = iso.string(from: created)
        parts.append(("docProps/core.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:creator>Koban</dc:creator><cp:lastModifiedBy>Koban</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(stamp)</dcterms:modified></cp:coreProperties>
        """))

        var titles = ""
        for n in names { titles += "<vt:lpstr>\(xmlEscape(n))</vt:lpstr>" }
        parts.append(("docProps/app.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Koban</Application><HeadingPairs><vt:vector size="2" baseType="variant"><vt:variant><vt:lpstr>Worksheets</vt:lpstr></vt:variant><vt:variant><vt:i4>\(names.count)</vt:i4></vt:variant></vt:vector></HeadingPairs><TitlesOfParts><vt:vector size="\(names.count)" baseType="lpstr">\(titles)</vt:vector></TitlesOfParts></Properties>
        """))

        var sheetsXML = ""
        var relsXML = ""
        for (i, name) in names.enumerated() {
            sheetsXML += "<sheet name=\"\(xmlEscape(name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            relsXML += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        let n = names.count
        relsXML += "<Relationship Id=\"rId\(n + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/>"
        relsXML += "<Relationship Id=\"rId\(n + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        relsXML += "<Relationship Id=\"rId\(n + 3)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"

        parts.append(("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><workbookPr/><bookViews><workbookView/></bookViews><sheets>\(sheetsXML)</sheets><calcPr calcId="0"/></workbook>
        """))
        parts.append(("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relsXML)</Relationships>
        """))

        for (i, xml) in sheetXMLs.enumerated() {
            parts.append(("xl/worksheets/sheet\(i + 1).xml", xml))
        }

        parts.append(("xl/theme/theme1.xml", themeXML))
        parts.append(("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><color theme="1"/><name val="Calibri"/><family val="2"/><scheme val="minor"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles><dxfs count="0"/><tableStyles count="0" defaultTableStyle="TableStyleMedium9" defaultPivotStyle="PivotStyleMedium4"/></styleSheet>
        """))

        var sstXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" count=\"\(stringRefCount)\" uniqueCount=\"\(sharedStrings.count)\">"
        for s in sharedStrings {
            let needsSpace = s.first?.isWhitespace == true || s.last?.isWhitespace == true || s.contains("\n")
            sstXML += needsSpace ? "<si><t xml:space=\"preserve\">\(xmlEscape(s))</t></si>" : "<si><t>\(xmlEscape(s))</t></si>"
        }
        sstXML += "</sst>"
        parts.append(("xl/sharedStrings.xml", sstXML))
        return parts
    }

    private static func uniqueSheetNames(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.enumerated().map { idx, name in
            var base = sanitizeSheetName(name)
            if base.isEmpty { base = "Sheet\(idx + 1)" }
            var candidate = base
            var n = 2
            while seen.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                candidate = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            seen.insert(candidate.lowercased())
            return candidate
        }
    }

    /// Writes the workbook to `url` (replacing an existing file).
    static func write(_ workbook: WorkbookData, to url: URL) throws {
        let data = try xlsxData(for: workbook)
        try data.write(to: url, options: .atomic)
    }

    static func xlsxData(for workbook: WorkbookData) throws -> Data {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("koban-xlsx-\(UUID().uuidString)", isDirectory: true)
        let staging = tmp.appendingPathComponent("pkg", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let allParts = parts(for: workbook)
        for (path, xml) in allParts {
            let fileURL = staging.appendingPathComponent(path)
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(xml.utf8).write(to: fileURL)
        }

        let out = tmp.appendingPathComponent("book.xlsx")
        // -X: no extra attributes, -nw: names are literal ("[Content_Types].xml" is not a pattern),
        // -D: no directory entries. [Content_Types].xml is listed first, as Excel expects.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = staging
        process.arguments = ["-X", "-q", "-D", "-nw", out.path] + allParts.map(\.0)
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { throw SpreadsheetError.zipFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw SpreadsheetError.zipFailed(msg.isEmpty ? "zip exited with \(process.terminationStatus)" : msg)
        }
        return try Data(contentsOf: out)
    }

    // A compact Office theme (Excel falls back gracefully without one, but Numbers and
    // older Excel builds are happier when it is present).
    private static let themeXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F497D"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2><a:accent1><a:srgbClr val="4F81BD"/></a:accent1><a:accent2><a:srgbClr val="C0504D"/></a:accent2><a:accent3><a:srgbClr val="9BBB59"/></a:accent3><a:accent4><a:srgbClr val="8064A2"/></a:accent4><a:accent5><a:srgbClr val="4BACC6"/></a:accent5><a:accent6><a:srgbClr val="F79646"/></a:accent6><a:hlink><a:srgbClr val="0000FF"/></a:hlink><a:folHlink><a:srgbClr val="800080"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Cambria"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
    """
}
