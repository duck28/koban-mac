# Golden ledger

`basic-ledger.json` is a small Koban ledger (the `LedgerState` JSON both apps store in `koban.db`)
that exercises the budget math: bi-weekly and bi-monthly schedules, a typed budget override,
fixed costs, typed Actuals, savings moved into a target account, account-to-account transfer
pairs, a manually valued account, a liability, freelancer VAT and a net-worth snapshot.

`basic-expected.json` holds what the apps must compute from it: month summaries, recurring due
dates, account balances and the net-worth history (with "today" fixed to 2026-01-15).

Both apps check the same files:

- **Windows:** `npm test` (`scripts/test-golden.ts`)
- **Mac:** `cd KobanKit && swift test` (`Tests/KobanCoreTests/GoldenLedgerTests.swift`)

The two repositories keep **identical copies** of this folder. When the math changes on purpose:

1. Change the code in both apps.
2. In koban-windows run `npm test -- --update-golden` and review the diff of `basic-expected.json`.
3. Copy `fixtures/golden/` to koban-mac and run `swift test` there.
