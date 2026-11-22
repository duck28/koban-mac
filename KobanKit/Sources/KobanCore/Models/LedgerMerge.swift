import Foundation

struct MergeSummary: Hashable, Sendable {
    var groupsAdded = 0
    var categoriesAdded = 0
    var budgetsMerged = 0
    var transactionsAdded = 0
    var transactionsUpdated = 0
    var rulesMerged = 0
    var goalsMerged = 0
    var accountsMerged = 0
    var snapshotsMerged = 0
    var planItemsMerged = 0

    var totalChanges: Int {
        groupsAdded +
        categoriesAdded +
        budgetsMerged +
        transactionsAdded +
        transactionsUpdated +
        rulesMerged +
        goalsMerged +
        accountsMerged +
        snapshotsMerged +
        planItemsMerged
    }
}

/// Deterministic record-level merge between two decrypted `LedgerState` values.
/// Mirrors `src/utils/ledgerMerge.ts` across Windows and macOS so both WebDAV conflict
/// resolution ("Merge Both Versions") and cloud-folder SHA-256 sync conflicts preserve
/// every entry from both devices without clobbering machine-local backup paths.
enum LedgerMerge {
    static func merge(
        local: LedgerState,
        remote: LedgerState,
        preferLocal: Bool = true
    ) -> (merged: LedgerState, summary: MergeSummary) {
        var summary = MergeSummary()

        let groups = mergeKeyed(
            local.groups,
            remote.groups,
            key: { $0.id },
            chooseRemote: { _, _ in !preferLocal }
        )
        summary.groupsAdded = groups.added

        let categories = mergeKeyed(
            local.categories,
            remote.categories,
            key: { $0.id },
            chooseRemote: { _, _ in !preferLocal }
        )
        summary.categoriesAdded = categories.added

        let budgets = mergeKeyed(
            local.monthlyBudgets,
            remote.monthlyBudgets,
            key: { "\($0.monthKey)::\($0.categoryId)" },
            chooseRemote: { _, _ in !preferLocal }
        )
        summary.budgetsMerged = budgets.added + budgets.updated

        var txs = mergeKeyed(
            local.transactions,
            remote.transactions,
            key: { $0.id },
            chooseRemote: { _, _ in !preferLocal }
        )
        txs.items.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }
        summary.transactionsAdded = txs.added
        summary.transactionsUpdated = txs.updated

        let rules = mergeKeyed(
            local.recurringRules,
            remote.recurringRules,
            key: { $0.id },
            chooseRemote: { _, _ in !preferLocal }
        )
        summary.rulesMerged = rules.added + rules.updated

        let goals = mergeKeyed(
            local.savingsGoals,
            remote.savingsGoals,
            key: { $0.id },
            chooseRemote: { _, _ in !preferLocal }
        )
        summary.goalsMerged = goals.added + goals.updated

        let accounts = mergeKeyed(
            local.accounts,
            remote.accounts,
            key: { $0.id },
            chooseRemote: { l, r in
                if r.updatedAt > l.updatedAt { return true }
                if l.updatedAt > r.updatedAt { return false }
                return !preferLocal
            }
        )
        summary.accountsMerged = accounts.added + accounts.updated

        let snapshots = mergeKeyed(
            local.netWorthSnapshots,
            remote.netWorthSnapshots,
            key: { $0.id },
            chooseRemote: { l, r in
                if r.recordedAt > l.recordedAt { return true }
                if l.recordedAt > r.recordedAt { return false }
                return !preferLocal
            }
        )
        summary.snapshotsMerged = snapshots.added + snapshots.updated

        let planItems = mergeKeyed(
            local.yearlyPlanItems ?? [],
            remote.yearlyPlanItems ?? [],
            key: { $0.id },
            chooseRemote: { _, _ in !preferLocal }
        )
        summary.planItemsMerged = planItems.added + planItems.updated

        let importProfiles = mergeKeyed(
            local.importProfiles ?? [],
            remote.importProfiles ?? [],
            key: { $0.id },
            chooseRemote: { l, r in
                if r.updatedAt > l.updatedAt { return true }
                if l.updatedAt > r.updatedAt { return false }
                return !preferLocal
            }
        )

        var importRules = mergeKeyed(
            local.importRules ?? [],
            remote.importRules ?? [],
            key: { $0.id },
            chooseRemote: { l, r in
                if r.updatedAt > l.updatedAt { return true }
                if l.updatedAt > r.updatedAt { return false }
                return !preferLocal
            }
        )
        importRules.items.sort { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }
        summary.rulesMerged += importProfiles.added + importProfiles.updated + importRules.added + importRules.updated

        var mergedSettings = preferLocal ? local.settings : remote.settings
        mergedSettings.setupCompleted = local.settings.setupCompleted || remote.settings.setupCompleted
        if (mergedSettings.ownerDisplayName ?? "").isEmpty {
            mergedSettings.ownerDisplayName = remote.settings.ownerDisplayName ?? local.settings.ownerDisplayName
        }
        // Keep device-local backup path and WebDAV configuration pinned to the active machine
        mergedSettings.backupDir = local.settings.backupDir
        mergedSettings.autoBackup = local.settings.autoBackup
        mergedSettings.maxBackups = local.settings.maxBackups
        mergedSettings.lastBackupAt = local.settings.lastBackupAt
        mergedSettings.lastBackupPath = local.settings.lastBackupPath
        mergedSettings.webdav = local.settings.webdav ?? remote.settings.webdav

        let merged = LedgerState(
            version: max(local.version, remote.version),
            settings: mergedSettings,
            groups: groups.items,
            categories: categories.items,
            monthlyBudgets: budgets.items,
            transactions: txs.items,
            recurringRules: rules.items,
            savingsGoals: goals.items,
            accounts: accounts.items,
            netWorthSnapshots: snapshots.items,
            yearlyPlanItems: planItems.items,
            importProfiles: importProfiles.items,
            importRules: importRules.items
        )
        return (merged, summary)
    }

    private static func mergeKeyed<T: Equatable>(
        _ localItems: [T],
        _ remoteItems: [T],
        key: (T) -> String,
        chooseRemote: (T, T) -> Bool
    ) -> (items: [T], added: Int, updated: Int) {
        var localByKey: [String: T] = [:]
        var remoteByKey: [String: T] = [:]
        for item in localItems { localByKey[key(item)] = item }
        for item in remoteItems { remoteByKey[key(item)] = item }

        var result: [T] = []
        result.reserveCapacity(localItems.count + remoteItems.count)
        var added = 0
        var updated = 0

        for localItem in localItems {
            let k = key(localItem)
            guard let remoteItem = remoteByKey[k] else {
                result.append(localItem)
                continue
            }
            if localItem == remoteItem {
                result.append(localItem)
                continue
            }
            if chooseRemote(localItem, remoteItem) {
                result.append(remoteItem)
                updated += 1
            } else {
                result.append(localItem)
            }
        }

        for remoteItem in remoteItems {
            let k = key(remoteItem)
            if localByKey[k] == nil {
                result.append(remoteItem)
                added += 1
            }
        }

        return (result, added, updated)
    }
}
