import Foundation

// Categories & Structure studio actions (App.tsx handleAddGroup / handleUpdateGroup /
// handleAddCategory / handleUpdateCategory). Deletes use store.deleteGroup / deleteCategory;
// the confirmation (settings.confirmBeforeDelete) is shown by the view.
extension LedgerStore {
    func addGroup(mode: LedgerMode, name: String, kind: CategoryKind, column: Int, color: String?) {
        update { $0.addGroup(mode: mode, name: name, kind: kind, column: column, color: color) }
        notify("Created group \"\(name)\".")
    }

    func updateGroup(_ id: String, _ patch: GroupPatch) {
        update { $0.updateGroup(id, patch) }
    }

    func addCategory(groupId: String, mode: LedgerMode, kind: CategoryKind, name: String,
                     defaultBudget: Double, taxRate: Double = 0, deductiblePct: Double = 100) {
        let key = state.activeMonthKey
        update {
            $0.addCategory(groupId: groupId, mode: mode, kind: kind, name: name, defaultBudget: defaultBudget,
                           taxRate: taxRate, deductiblePct: deductiblePct, monthKey: key)
        }
    }

    func updateCategory(_ id: String, _ patch: CategoryPatch) {
        update { $0.updateCategory(id, patch) }
    }

    func moveGroup(_ id: String, by delta: Int) { update { $0.moveGroup(id, by: delta) } }
    func moveCategory(_ id: String, by delta: Int) { update { $0.moveCategory(id, by: delta) } }
    func moveCategory(_ id: String, toGroup groupId: String) { update { $0.moveCategory(id, toGroup: groupId) } }
}
