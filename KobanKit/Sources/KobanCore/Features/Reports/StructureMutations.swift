import Foundation

// Categories & Structure studio mutations, ported from handleAddGroup / handleUpdateGroup /
// handleAddCategory / handleUpdateCategory in src/App.tsx. Deletes reuse deleteGroup /
// deleteCategory from Models/LedgerMutations.swift.

/// Partial<Pick<CategoryGroup, 'name' | 'color' | 'column' | 'kind'>>
struct GroupPatch: Hashable, Sendable {
    var name: String?
    var color: String?
    var column: Int?
    var kind: CategoryKind?
}

/// Partial<Pick<CategoryItem, 'name' | 'defaultBudget' | 'taxRate' | 'deductiblePct'>>
struct CategoryPatch: Hashable, Sendable {
    var name: String?
    var defaultBudget: Double?
    var taxRate: Double?
    var deductiblePct: Double?
}

extension LedgerState {
    /// handleAddGroup: like `addGroup(mode:name:kind:column:)` but with an optional explicit color.
    /// Returns the new group's id.
    @discardableResult
    mutating func addGroup(mode: LedgerMode, name: String, kind: CategoryKind, column: Int,
                           color: String?) -> String {
        let fallback = kind == .income
            ? "#3f704d"
            : ZenGroupPalette.colors[groups.count % ZenGroupPalette.colors.count]
        let resolved = (color?.isEmpty == false) ? color! : fallback
        let id = KobanID.make("grp", suffix: false)
        groups.append(CategoryGroup(
            id: id,
            mode: mode,
            name: name,
            kind: kind,
            color: resolved,
            column: column,
            order: groups.filter { $0.mode == mode }.count
        ))
        return id
    }

    /// handleUpdateGroup: `{ ...g, ...patch }`.
    mutating func updateGroup(_ groupId: String, _ patch: GroupPatch) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        if let v = patch.name { groups[idx].name = v }
        if let v = patch.color { groups[idx].color = v }
        if let v = patch.column { groups[idx].column = v }
        if let v = patch.kind { groups[idx].kind = v }
    }

    /// handleAddCategory with the full signature (taxRate = 0, deductiblePct = 100 defaults).
    /// Also creates the month entry for `monthKey`. Returns the new category's id.
    @discardableResult
    mutating func addCategory(groupId: String, mode: LedgerMode, kind: CategoryKind, name: String,
                              defaultBudget: Double, taxRate: Double = 0, deductiblePct: Double = 100,
                              monthKey: String) -> String {
        let cat = CategoryItem(
            id: KobanID.make("cat"),
            groupId: groupId,
            mode: mode,
            name: name,
            kind: kind,
            defaultBudget: defaultBudget,
            taxRate: taxRate,
            deductiblePct: deductiblePct,
            order: categories.filter { $0.groupId == groupId }.count
        )
        categories.append(cat)
        monthlyBudgets.append(MonthlyBudgetEntry(monthKey: monthKey, categoryId: cat.id,
                                                 budget: defaultBudget, directActual: nil))
        return cat.id
    }

    /// handleUpdateCategory: `{ ...c, ...patch }`.
    mutating func updateCategory(_ categoryId: String, _ patch: CategoryPatch) {
        guard let idx = categories.firstIndex(where: { $0.id == categoryId }) else { return }
        if let v = patch.name { categories[idx].name = v }
        if let v = patch.defaultBudget { categories[idx].defaultBudget = v }
        if let v = patch.taxRate { categories[idx].taxRate = v }
        if let v = patch.deductiblePct { categories[idx].deductiblePct = v }
    }

    // MARK: - Reorder / move helpers
    // (No Windows UI calls these yet; exposed for other features. Orders are renumbered 0…n-1.)

    /// Moves a group up (`delta < 0`) or down within its mode, renumbering `order`.
    mutating func moveGroup(_ groupId: String, by delta: Int) {
        guard let group = groups.first(where: { $0.id == groupId }) else { return }
        var ids = groups.filter { $0.mode == group.mode }.sorted { $0.order < $1.order }.map(\.id)
        guard let from = ids.firstIndex(of: groupId) else { return }
        let to = min(max(0, from + delta), ids.count - 1)
        guard to != from else { return }
        ids.remove(at: from)
        ids.insert(groupId, at: to)
        for (order, id) in ids.enumerated() {
            if let i = groups.firstIndex(where: { $0.id == id }) { groups[i].order = order }
        }
    }

    /// Moves a category up / down within its group, renumbering `order`.
    mutating func moveCategory(_ categoryId: String, by delta: Int) {
        guard let cat = categories.first(where: { $0.id == categoryId }) else { return }
        var ids = categories.filter { $0.groupId == cat.groupId }.sorted { $0.order < $1.order }.map(\.id)
        guard let from = ids.firstIndex(of: categoryId) else { return }
        let to = min(max(0, from + delta), ids.count - 1)
        guard to != from else { return }
        ids.remove(at: from)
        ids.insert(categoryId, at: to)
        renumberCategories(ids)
    }

    /// Moves a category into another group (appended last; takes the target group's mode & kind).
    mutating func moveCategory(_ categoryId: String, toGroup groupId: String) {
        guard let cIdx = categories.firstIndex(where: { $0.id == categoryId }),
              let target = groups.first(where: { $0.id == groupId }),
              categories[cIdx].groupId != groupId else { return }
        let oldGroup = categories[cIdx].groupId
        categories[cIdx].groupId = groupId
        categories[cIdx].mode = target.mode
        categories[cIdx].kind = target.kind
        categories[cIdx].order = categories.filter { $0.groupId == groupId && $0.id != categoryId }.count
        renumberCategories(categories.filter { $0.groupId == oldGroup }.sorted { $0.order < $1.order }.map(\.id))
    }

    private mutating func renumberCategories(_ orderedIds: [String]) {
        for (order, id) in orderedIds.enumerated() {
            if let i = categories.firstIndex(where: { $0.id == id }) { categories[i].order = order }
        }
    }
}
