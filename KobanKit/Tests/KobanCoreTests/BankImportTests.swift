import XCTest
@testable import KobanCore

final class BankImportTests: XCTestCase {
    private func utf8Data(_ text: String, withBom: Bool = false) -> Data {
        let body = Data(text.utf8)
        guard withBom else { return body }
        var out = Data([0xEF, 0xBB, 0xBF])
        out.append(body)
        return out
    }

    func testFingerprintMatchesTypeScriptCrossPlatformVector() {
        let fp0 = BankImport.computeImportFingerprint(
            accountId: "acc-1",
            date: "2026-11-15",
            signedAmount: -48.9,
            normalizedKey: "migros zurich",
            occurrenceIndex: 0
        )
        let fp1 = BankImport.computeImportFingerprint(
            accountId: "acc-1",
            date: "2026-11-15",
            signedAmount: -48.9,
            normalizedKey: "migros zurich",
            occurrenceIndex: 1
        )
        XCTAssertEqual(fp0, "24badbda3dd689d2aec70e859ce55b4d")
        XCTAssertNotEqual(fp0, fp1)
        XCTAssertEqual(
            BankImport.normalizeMerchantText("TWINT Zahlung Migros Zürich XXXX-1234 15.11.2026"),
            "migros zurich"
        )
        XCTAssertEqual(
            BankImport.suggestRulePattern(rawPayee: "Migros Zürich Bahnhof", rawDescription: ""),
            "migros zurich"
        )
    }

    func testNumberAndDateParsersIncludingExcelSerial() {
        XCTAssertEqual(BankImport.parseBankNumber("1'234.50", decimalSep: .auto), 1234.5)
        XCTAssertEqual(BankImport.parseBankNumber("1.234,50", decimalSep: .auto), 1234.5)
        XCTAssertEqual(BankImport.parseBankNumber("(45.00)", decimalSep: .auto), -45.0)
        XCTAssertEqual(BankImport.parseBankNumber("42,80-", decimalSep: .comma), -42.8)
        XCTAssertEqual(BankImport.parseBankDate("15.11.2026", format: .chDot), "2026-11-15")
        XCTAssertEqual(BankImport.parseBankDate("45611", format: .auto), "2024-11-15")
    }

    func testParsesCamt053SingleAndBatchEntries() throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <Document xmlns="urn:iso:std:iso:20022:tech:xsd:camt.053.001.08">
          <BkToCstmrStmt>
            <Stmt>
              <Acct>
                <Id><IBAN>CH9300762011623852957</IBAN></Id>
                <Ccy>CHF</Ccy>
              </Acct>
              <Ntry>
                <Amt Ccy="CHF">5200.00</Amt>
                <CdtDbtInd>CRDT</CdtDbtInd>
                <BookgDt><Dt>2026-11-01</Dt></BookgDt>
                <AcctSvcrRef>CAMT-SALA-001</AcctSvcrRef>
                <BkTxCd><Domn><Fmly><SubFmlyCd>SALA</SubFmlyCd></Fmly></Domn></BkTxCd>
                <NtryDtls><TxDtls>
                  <RltdPties><Dbtr><Nm>Helvetia Tech AG</Nm></Dbtr></RltdPties>
                  <RmtInf><Ustrd>November Salary &amp; Bonus</Ustrd></RmtInf>
                </TxDtls></NtryDtls>
              </Ntry>
              <Ntry>
                <Amt Ccy="CHF">150.00</Amt>
                <CdtDbtInd>DBIT</CdtDbtInd>
                <BookgDt><Dt>2026-11-05</Dt></BookgDt>
                <BkTxCd><Domn><Fmly><SubFmlyCd>PMNT</SubFmlyCd></Fmly></Domn></BkTxCd>
                <NtryDtls>
                  <TxDtls>
                    <Amt Ccy="CHF">100.00</Amt>
                    <CdtDbtInd>DBIT</CdtDbtInd>
                    <Refs><AcctSvcrRef>CAMT-BATCH-1</AcctSvcrRef></Refs>
                    <RltdPties>
                      <Cdtr><Nm>O&apos;Connor Books &amp; Press</Nm></Cdtr>
                      <CdtrAcct><Id><IBAN>CH1000230001234567890</IBAN></Id></CdtrAcct>
                    </RltdPties>
                    <RmtInf><Ustrd>Technical Reference</Ustrd></RmtInf>
                  </TxDtls>
                  <TxDtls>
                    <Amt Ccy="CHF">50.00</Amt>
                    <CdtDbtInd>DBIT</CdtDbtInd>
                    <Refs><AcctSvcrRef>CAMT-BATCH-2</AcctSvcrRef></Refs>
                    <RltdPties><Cdtr><Nm>SBB CFF FFS</Nm></Cdtr></RltdPties>
                    <RmtInf><Ustrd>Train ticket</Ustrd></RmtInf>
                  </TxDtls>
                </NtryDtls>
              </Ntry>
            </Stmt>
          </BkToCstmrStmt>
        </Document>
        """#

        let parsed = try BankImport.parseStatement(data: utf8Data(xml), fileName: "statement.xml")
        XCTAssertEqual(parsed.format, .camt053)
        XCTAssertEqual(parsed.detectedAccountIban, "CH9300762011623852957")
        XCTAssertEqual(parsed.detectedCurrency, "CHF")
        XCTAssertEqual(parsed.rawTransactions.count, 3)
        XCTAssertEqual(parsed.rawTransactions[0].signedAmount, 5200.0)
        XCTAssertEqual(parsed.rawTransactions[0].externalId, "CAMT-SALA-001")
        XCTAssertEqual(parsed.rawTransactions[0].bankTxCode, "SALA")
        XCTAssertEqual(parsed.rawTransactions[1].signedAmount, -100.0)
        XCTAssertEqual(parsed.rawTransactions[1].rawPayee, "O'Connor Books & Press")
        XCTAssertEqual(parsed.rawTransactions[1].counterpartyIban, "CH1000230001234567890")
        XCTAssertEqual(parsed.rawTransactions[2].signedAmount, -50.0)
    }

    func testParsesOfxSgmlAndXml() throws {
        let sgml = """
        OFXHEADER:100
        DATA:OFXSGML
        VERSION:102

        <OFX>
        <BANKMSGSRSV1><STMTTRNRS><STMTRS>
        <CURDEF>CHF
        <BANKACCTFROM><ACCTID>CH93000011112222</BANKACCTFROM>
        <BANKTRANLIST>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20261110120000[+1:CET]
        <TRNAMT>-64.50
        <FITID>OFX-101
        <NAME>Coop Pronto
        <MEMO>Card purchase Zurich
        </STMTTRN>
        </BANKTRANLIST>
        </STMTRS></STMTTRNRS></BANKMSGSRSV1>
        </OFX>
        """
        let p1 = try BankImport.parseStatement(data: utf8Data(sgml), fileName: "bank.ofx")
        XCTAssertEqual(p1.format, .ofx)
        XCTAssertEqual(p1.rawTransactions.count, 1)
        XCTAssertEqual(p1.rawTransactions[0].date, "2026-11-10")
        XCTAssertEqual(p1.rawTransactions[0].signedAmount, -64.5)
        XCTAssertEqual(p1.rawTransactions[0].externalId, "OFX-101")
        XCTAssertEqual(p1.rawTransactions[0].rawPayee, "Coop Pronto")

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <OFX><CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>USD</CURDEF>
        <BANKTRANLIST>
          <STMTTRN>
            <TRNTYPE>PAYMENT</TRNTYPE>
            <DTPOSTED>20261112</DTPOSTED>
            <TRNAMT>300.00</TRNAMT>
            <FITID>OFX-V2-9</FITID>
            <NAME>Client Wire</NAME>
            <MEMO>Invoice 88</MEMO>
          </STMTTRN>
        </BANKTRANLIST>
        </CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>
        """
        let p2 = try BankImport.parseStatement(data: utf8Data(xml), fileName: "card.qfx")
        XCTAssertEqual(p2.format, .ofx)
        XCTAssertEqual(p2.detectedCurrency, "USD")
        XCTAssertEqual(p2.rawTransactions.count, 1)
        XCTAssertEqual(p2.rawTransactions[0].signedAmount, 300.0)
        XCTAssertEqual(p2.rawTransactions[0].externalId, "OFX-V2-9")
    }

    func testSmartCsvPreambleBomSplitDebitCreditAndInvertSign() throws {
        let ubsCsv = [
            "Account:;CH93 0023 0000 1234 5678 9",
            "Currency:;CHF",
            "Trade date;Description1;Description2;Debit;Credit;Valuta",
            "15.11.2026;Migros Zurich;POS Purchase;1'234.50;;15.11.2026",
            "16.11.2026;Acme GmbH;Consulting;;2'500.00;16.11.2026",
            "17.11.2026;Account Maintenance Fee;Quarterly;(45.00);;17.11.2026",
        ].joined(separator: "\r\n")

        let parsed = try BankImport.parseStatement(data: utf8Data(ubsCsv, withBom: true), fileName: "ubs.csv")
        XCTAssertEqual(parsed.format, .csv)
        XCTAssertEqual(parsed.delimiter, ";")
        XCTAssertEqual(parsed.headerRowIndex, 2)
        XCTAssertEqual(parsed.detectedAccountIban, "CH9300230000123456789")
        XCTAssertEqual(parsed.matchedProfile?.id, "builtin-ubs-ch")
        XCTAssertFalse(parsed.needsMappingReview)
        XCTAssertEqual(parsed.rawTransactions.count, 3)
        XCTAssertEqual(parsed.rawTransactions[0].date, "2026-11-15")
        XCTAssertEqual(parsed.rawTransactions[0].signedAmount, -1234.5)
        XCTAssertEqual(parsed.rawTransactions[0].rawDescription, "Migros Zurich · POS Purchase")
        XCTAssertEqual(parsed.rawTransactions[1].signedAmount, 2500.0)
        XCTAssertEqual(parsed.rawTransactions[2].signedAmount, -45.0)

        let ubsDeCsv = [
            "Kontonummer:;CH10 0023 0000 9999 8888 1",
            "Abschlussdatum;Valutadatum;Währung;Belastung;Gutschrift;Transaktions-Nr.;Beschreibung1;Beschreibung2;Beschreibung3",
            "22.11.2026;22.11.2026;CHF;18.90;;TX-991;Coop City;Zürich;Einkauf",
        ].joined(separator: "\n")
        let ubsDeParsed = try BankImport.parseStatement(data: utf8Data(ubsDeCsv), fileName: "transactions_20261122185604.csv")
        XCTAssertEqual(ubsDeParsed.matchedProfile?.id, "builtin-ubs-ch")
        XCTAssertFalse(ubsDeParsed.needsMappingReview)
        XCTAssertEqual(ubsDeParsed.detectedAccountIban, "CH1000230000999988881")
        XCTAssertEqual(ubsDeParsed.rawTransactions[0].rawDescription, "Coop City · Zürich · Einkauf")

        let yuhCsv = "DATE;ACTIVITY TYPE;ACTIVITY NAME;DEBIT;CREDIT;PAYMENT CURRENCY\n2026-11-20;Card;SBB Mobile;24.50;;CHF\n"
        let yuhExplicit = try BankImport.parseStatement(data: utf8Data(yuhCsv), fileName: "yuh.csv", selectedProfileId: "builtin-yuh-ch")
        XCTAssertEqual(yuhExplicit.matchedProfile?.id, "builtin-yuh-ch")
        XCTAssertFalse(yuhExplicit.needsMappingReview)
        XCTAssertEqual(yuhExplicit.rawTransactions[0].signedAmount, -24.5)
        XCTAssertEqual(yuhExplicit.rawTransactions[0].rawDescription, "SBB Mobile · Card")

        let reparsedCustom = BankImport.reparseWithProfile(yuhExplicit, selectedProfileId: "custom")
        XCTAssertEqual(reparsedCustom.selectedProfileId, "custom")
        XCTAssertTrue(reparsedCustom.needsMappingReview)

        let oddCsv = "Tag;Code;Summe\n20.11.2026;A1;99.00\n"
        let mismatched = try BankImport.parseStatement(data: utf8Data(oddCsv), fileName: "odd.csv", selectedProfileId: "builtin-ubs-ch")
        XCTAssertTrue(mismatched.needsMappingReview)
        XCTAssertFalse(mismatched.warnings.isEmpty)

        let cardCsv = "Date;Merchant;Amount\n18.11.2026;Starbucks Berlin;1.234,50\n"
        let ccParsed = try BankImport.parseStatement(data: utf8Data(cardCsv), fileName: "card.csv")
        XCTAssertEqual(ccParsed.rawTransactions[0].signedAmount, 1234.5)
        var invertedProfile = try XCTUnwrap(ccParsed.activeMapping)
        invertedProfile.invertSign = true
        let extracted = BankImport.extractRawTransactions(
            matrix: ccParsed.rawRows ?? [],
            headerRowIndex: ccParsed.headerRowIndex ?? 0,
            profile: invertedProfile,
            fallbackCurrency: "CHF"
        )
        XCTAssertEqual(extracted.rawTransactions[0].signedAmount, -1234.5)
    }

    func testDedupTransfersCascadeApplyAndMergeParity() throws {
        var state = KobanTemplates.initialLedgerState(setupMode: .both, currency: "CHF", setupCompleted: true)
        let checkingAcc = state.accounts[0]
        let savingsAcc = state.accounts.count > 1 ? state.accounts[1] : FinancialAccount(
            id: "acc-sav",
            name: "Savings",
            institution: "Bank",
            mode: .home,
            type: .savings,
            classification: .liquid,
            startingBalance: 0,
            currentBalance: 0,
            autoTrackTransactions: true,
            includeInNetWorth: true,
            color: "#3f704d",
            updatedAt: "2026-11-01"
        )
        if state.accounts.count == 1 {
            state.accounts.append(savingsAcc)
        }

        let fp0 = BankImport.computeImportFingerprint(
            accountId: checkingAcc.id,
            date: "2026-11-15",
            signedAmount: -5.5,
            normalizedKey: "kiosk coffee",
            occurrenceIndex: 0
        )

        state.transactions = [
            TransactionItem(
                id: "tx-ext-1", date: "2026-11-01", monthKey: "2026-11",
                mode: .home, type: .expense, categoryId: "home-dl-groceries",
                accountId: checkingAcc.id, description: "Already Imported Ref", amount: 33.3,
                externalId: "EXT-DUP-1"
            ),
            TransactionItem(
                id: "tx-fp-0", date: "2026-11-15", monthKey: "2026-11",
                mode: .home, type: .expense, categoryId: "home-dl-dining",
                accountId: checkingAcc.id, description: "Kiosk Coffee #1", amount: 5.5,
                importFingerprint: fp0
            ),
            TransactionItem(
                id: "tx-fuzzy-1", date: "2026-11-12", monthKey: "2026-11",
                mode: .home, type: .expense, categoryId: "home-dl-dining",
                accountId: checkingAcc.id, description: "Bistro Old Entry", amount: 88.0
            ),
            TransactionItem(
                id: "tx-xfer-peer", date: "2026-11-14", monthKey: "2026-11",
                mode: .home, type: .income, categoryId: "home-inc-savings-transfer",
                accountId: savingsAcc.id, description: "Transfer in", amount: 750.0
            ),
            TransactionItem(
                id: "tx-hist-1", date: "2026-10-05", monthKey: "2026-10",
                mode: .home, type: .expense, categoryId: "home-dl-dining",
                accountId: checkingAcc.id, description: "Roastery XYZ", amount: 12.0
            ),
            TransactionItem(
                id: "tx-hist-2", date: "2026-10-19", monthKey: "2026-10",
                mode: .home, type: .expense, categoryId: "home-dl-dining",
                accountId: checkingAcc.id, description: "Roastery XYZ", amount: 14.0
            ),
            TransactionItem(
                id: "tx-hist-once", date: "2026-10-20", monthKey: "2026-10",
                mode: .home, type: .expense, categoryId: "home-dl-dining",
                accountId: checkingAcc.id, description: "Single Time Shop", amount: 9.0
            ),
        ]

        let rule = ImportRule(
            id: "rule-special",
            name: "Special Studio Override",
            enabled: true,
            priority: 1,
            accountId: nil,
            direction: .any,
            matchField: .any,
            matchType: .contains,
            pattern: "special studio",
            minAmount: nil,
            maxAmount: nil,
            setCategoryId: "biz-sw-design",
            setMode: nil,
            setPayee: "Special Studio Clean",
            setClient: "Internal Studio",
            setTaxRate: 8.1,
            setDeductiblePct: 80,
            markAsTransfer: nil,
            createdAt: "2026-11-01",
            updatedAt: "2026-11-01"
        )

        let raw: [RawBankTransaction] = [
            RawBankTransaction(rowIndex: 1, date: "2026-11-01", signedAmount: -33.3, currency: "CHF", externalId: "EXT-DUP-1", rawPayee: "Migros", rawDescription: "Migros", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 2, date: "2026-11-15", signedAmount: -5.5, currency: "CHF", externalId: nil, rawPayee: "Kiosk Coffee", rawDescription: "Kiosk Coffee", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 3, date: "2026-11-15", signedAmount: -5.5, currency: "CHF", externalId: nil, rawPayee: "Kiosk Coffee", rawDescription: "Kiosk Coffee", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 4, date: "2026-11-13", signedAmount: -88.0, currency: "CHF", externalId: nil, rawPayee: "Bistro", rawDescription: "Bistro Zurich", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 5, date: "2026-11-14", signedAmount: -750.0, currency: "CHF", externalId: nil, rawPayee: "Savings Sweep", rawDescription: "Savings Sweep", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 6, date: "2026-11-16", signedAmount: -120.0, currency: "CHF", externalId: nil, rawPayee: "SPECIAL STUDIO PRO", rawDescription: "SPECIAL STUDIO PRO #42", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 7, date: "2026-11-17", signedAmount: -15.0, currency: "CHF", externalId: nil, rawPayee: "Roastery XYZ", rawDescription: "Roastery XYZ Zurich", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 8, date: "2026-11-18", signedAmount: 5200.0, currency: "CHF", externalId: nil, rawPayee: "Employer AG", rawDescription: "Salary", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: "SALA"),
            RawBankTransaction(rowIndex: 9, date: "2026-11-19", signedAmount: -48.9, currency: "CHF", externalId: nil, rawPayee: "Migros Zurich", rawDescription: "TWINT Migros Zurich", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 10, date: "2026-11-20", signedAmount: -9.0, currency: "CHF", externalId: nil, rawPayee: "Single Time Shop", rawDescription: "Single Time Shop", reference: nil, counterpartyIban: nil, categoryHint: nil, bankTxCode: nil),
            RawBankTransaction(rowIndex: 11, date: "2026-11-21", signedAmount: -22.0, currency: "CHF", externalId: nil, rawPayee: "Corner Store", rawDescription: "Corner Store", reference: nil, counterpartyIban: nil, categoryHint: "Groceries", bankTxCode: nil),
        ]

        let staged = BankImport.stageBankTransactions(
            rawTransactions: raw,
            state: state,
            targetMode: .home,
            accountId: checkingAcc.id,
            rulesOverride: [rule]
        )

        XCTAssertEqual(staged[0].duplicateStatus, .exactDuplicate)
        XCTAssertFalse(staged[0].included)
        XCTAssertEqual(staged[1].duplicateStatus, .exactDuplicate)
        XCTAssertFalse(staged[1].included)
        XCTAssertEqual(staged[2].duplicateStatus, .none)
        XCTAssertTrue(staged[2].included)
        XCTAssertEqual(staged[3].duplicateStatus, .possibleDuplicate)
        XCTAssertFalse(staged[3].included)
        XCTAssertTrue(staged[4].isTransferCandidate)
        XCTAssertEqual(staged[4].transferPeerId, "tx-xfer-peer")

        XCTAssertEqual(staged[5].confidence, .rule)
        XCTAssertEqual(staged[5].categoryId, "biz-sw-design")
        XCTAssertEqual(staged[5].mode, .freelancer)
        XCTAssertEqual(staged[5].description, "Special Studio Clean")

        XCTAssertEqual(staged[6].confidence, .history)
        XCTAssertEqual(staged[6].categoryId, "home-dl-dining")

        XCTAssertEqual(staged[7].confidence, .keyword)
        XCTAssertEqual(staged[7].categoryId, "home-inc-wages")

        XCTAssertEqual(staged[8].confidence, .keyword)
        XCTAssertEqual(staged[8].categoryId, "home-dl-groceries")

        XCTAssertEqual(staged[9].confidence, .needsReview)
        XCTAssertNil(staged[9].categoryId)

        XCTAssertEqual(staged[10].confidence, .keyword)
        XCTAssertEqual(staged[10].categoryId, "home-dl-groceries")

        let customProfile = BankImportProfile(
            id: "prof-custom-1",
            name: "Local Profile",
            accountId: checkingAcc.id,
            defaultMode: .home,
            headerFingerprint: ["Date", "Merchant", "Amount"],
            delimiter: ";",
            dateColumn: "Date",
            dateFormat: .chDot,
            amountMode: .signed,
            amountColumn: "Amount",
            debitColumn: nil,
            creditColumn: nil,
            invertSign: false,
            decimalSeparator: .comma,
            descriptionColumns: ["Merchant"],
            payeeColumn: "Merchant",
            referenceColumn: nil,
            currencyColumn: nil,
            skipRows: nil,
            updatedAt: "2026-11-20"
        )

        let committed = BankImport.applyStagedTransactionsToLedger(
            stagedRows: staged,
            currentState: state,
            savedProfile: customProfile,
            savedRules: [rule]
        )
        XCTAssertEqual(committed.transactions.count, state.transactions.count + 8)
        XCTAssertEqual(committed.transactions.first(where: { $0.description == "Special Studio Clean" })?.rawDescription, "SPECIAL STUDIO PRO #42")

        var remote = KobanTemplates.initialLedgerState(setupMode: .both, currency: "CHF", setupCompleted: true)
        var remoteProf = customProfile
        remoteProf.name = "Remote Updated Profile"
        remoteProf.updatedAt = "2026-11-22"
        remote.importProfiles = [remoteProf]
        var remoteRule2 = rule
        remoteRule2.id = "rule-remote-2"
        remoteRule2.priority = 1
        var updatedLocalRule = rule
        updatedLocalRule.priority = 5
        var local = committed
        local.importRules = [updatedLocalRule]
        remote.importRules = [updatedLocalRule, remoteRule2]

        let merged = LedgerMerge.merge(local: local, remote: remote, preferLocal: true)
        XCTAssertEqual(merged.merged.importProfiles?.first?.name, "Remote Updated Profile")
        XCTAssertEqual(merged.merged.importRules?.count, 2)
        XCTAssertEqual(merged.merged.importRules?.first?.id, "rule-remote-2")
        XCTAssertGreaterThanOrEqual(merged.summary.rulesMerged, 1)
    }

    func testScanAndArchiveImportFolder() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("koban-import-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let stmt = tmp.appendingPathComponent("bank.camt.xml")
        let note = tmp.appendingPathComponent("readme.txt")
        let hidden = tmp.appendingPathComponent(".DS_Store")
        try Data("<Document/>".utf8).write(to: stmt)
        try Data("ignore".utf8).write(to: note)
        try Data("ignore".utf8).write(to: hidden)

        let scanned = DataIOStorage.scanImportFolder(in: tmp.path)
        XCTAssertEqual(scanned.map(\.name), ["bank.camt.xml"])

        let archived = try DataIOStorage.archiveImportedFile(at: stmt)
        XCTAssertFalse(fm.fileExists(atPath: stmt.path))
        XCTAssertTrue(fm.fileExists(atPath: archived.path))
        XCTAssertEqual(archived.deletingLastPathComponent().lastPathComponent, "Imported")
        XCTAssertTrue(DataIOStorage.scanImportFolder(in: tmp.path).isEmpty)
    }
}
