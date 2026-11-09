import AppKit
import SwiftUI

/// Port of src/components/CategoriesStudioView.tsx — "Categories & Structure" studio:
/// create / rename / recolor / delete groups, move them between worksheet columns, add curated
/// or custom categories, edit default budget, VAT % and deductible %, toggle recurring.
struct CategoriesView: View {
    @Environment(LedgerStore.self) private var store

    @State private var editMode: LedgerMode?
    @State private var newGroupName = ""
    @State private var newGroupKind: CategoryKind = .expense
    @State private var newGroupCol = 0
    @State private var newGroupColor = ZenGroupPalette.colors[1]

    @State private var addingCatToGroup: String?
    @State private var catName = ""
    @State private var catBudget = ""
    @State private var catTax = "8.1"
    @State private var catDed = "100"

    @State private var pendingDelete: DeleteTarget?
    @State private var contentWidth: CGFloat = 1000

    enum DeleteTarget: Identifiable {
        case category(id: String, name: String)
        case group(id: String, name: String)
        var id: String {
            switch self {
            case .category(let id, _), .group(let id, _): return id
            }
        }
    }

    /// initialMode in App.tsx: freelancer workspace → freelancer, otherwise home.
    private var mode: LedgerMode {
        editMode ?? (store.state.settings.activeWorkspace == .freelancer ? .freelancer : .home)
    }

    var body: some View {
        let state = store.state
        let mode = self.mode
        let modeGroups = state.groups.filter { $0.mode == mode }.sorted { $0.order < $1.order }
        let catalog = mode == .home ? KobanTemplates.homeCatalog : KobanTemplates.freelancerCatalog
        let viewport = contentWidth + 48 + (store.isSidebarOpen ? 256 : 0)
        let columns = viewport >= 1024 ? 2 : 1

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(state: state, mode: mode).id("top")
                    addGroupForm(mode: mode)

                    Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 20) {
                        ForEach(Array(stride(from: 0, to: modeGroups.count, by: columns)), id: \.self) { start in
                            GridRow(alignment: .top) {
                                ForEach(start..<min(start + columns, modeGroups.count), id: \.self) { i in
                                    groupCard(modeGroups[i], mode: mode, catalog: catalog,
                                              currency: state.settings.currency)
                                }
                                if columns == 2 && start + 1 >= modeGroups.count {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(24)
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 - 48 }
            }
            .scrollContentBackground(.hidden)
            .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { note in
                switch note.userInfo?["name"] as? String {
                case "categories.freelancer": editMode = .freelancer
                case "categories.home": editMode = .home
                case "categories.add":
                    addingCatToGroup = modeGroups.first?.id
                case "categories.add.freelancer":
                    editMode = .freelancer
                    addingCatToGroup = store.state.groups.filter { $0.mode == .freelancer }
                        .sorted { $0.order < $1.order }.first?.id
                case "categories.bottom": proxy.scrollTo("bottom", anchor: .bottom)
                default: break
                }
            }
        }
        .alert(item: $pendingDelete) { target in
            switch target {
            case .category(let id, let name):
                return Alert(title: Text("Are you sure you want to delete category \"\(name)\"?"),
                             primaryButton: .destructive(Text("Delete")) { store.deleteCategory(id) },
                             secondaryButton: .cancel())
            case .group(let id, let name):
                return Alert(title: Text("Are you sure you want to delete the \"\(name)\" group and all categories inside it?"),
                             primaryButton: .destructive(Text("Delete")) { store.deleteGroup(id) },
                             secondaryButton: .cancel())
            }
        }
    }

    private func requestDelete(_ target: DeleteTarget) {
        if store.state.settings.confirmBeforeDelete == false {
            switch target {
            case .category(let id, _): store.deleteCategory(id)
            case .group(let id, _): store.deleteGroup(id)
            }
        } else {
            pendingDelete = target
        }
    }

    // MARK: - Header

    private func header(state: LedgerState, mode: LedgerMode) -> some View {
        let homeCount = state.categories.filter { $0.mode == .home }.count
        let freelancerCount = state.categories.filter { $0.mode == .freelancer }.count
        let title = VStack(alignment: .leading, spacing: 2) {
            Text("Categories & Structure")
                .font(.zen(20))
                .foregroundStyle(Zen.ink)
            Text("Add, rename, reorder, or toggle categories across your Home and Freelancer workspaces.")
                .font(.zen(12))
                .foregroundStyle(Zen.ink2)
        }
        let actions = HStack(spacing: 8) {
            Button { store.openSetupWizard() } label: {
                HStack(spacing: 6) {
                    ZIcon("sparkles", size: 14).foregroundStyle(Zen.accent)
                    Text("Quick Category Picker")
                }
            }
            .buttonStyle(.zenOutline)

            Button { store.openImport() } label: {
                HStack(spacing: 6) {
                    ZIcon("square.and.arrow.up", size: 14).foregroundStyle(Zen.indigo)
                    Text("Import from Excel / CSV…")
                }
            }
            .buttonStyle(.zenOutline)

            HStack(spacing: 4) {
                modeButton("Home (\(homeCount))", .home, current: mode)
                modeButton("Freelancer (\(freelancerCount))", .freelancer, current: mode)
            }
            .padding(4)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
        }
        .fixedSize()

        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) { title; Spacer(minLength: 12); actions }
            VStack(alignment: .leading, spacing: 12) { title; actions }
        }
    }

    private func modeButton(_ label: String, _ value: LedgerMode, current: LedgerMode) -> some View {
        let active = current == value
        return Button {
            editMode = value
            addingCatToGroup = nil
        } label: {
            Text(label)
                .font(.zen(12, active ? .medium : .regular))
                .foregroundStyle(active ? Zen.onInk : Zen.ink2)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(active ? Zen.ink : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Add group form

    private func addGroupForm(mode: LedgerMode) -> some View {
        FlowLayout(spacing: 12, alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                formLabel("New \(mode == .home ? "Home" : "Freelancer") Category Group Name")
                TextField("", text: $newGroupName,
                          prompt: Text("e.g. INVESTMENTS, CHILDCARE, STUDIO GEAR").foregroundStyle(Zen.ink3))
                    .zenField(height: 32)
                    .onSubmit { createGroup(mode: mode) }
            }
            .frame(width: max(200, contentWidth - 32 - formFixedWidth))

            VStack(alignment: .leading, spacing: 4) {
                formLabel("Kind")
                ZenSelect(options: [(CategoryKind.expense, "Expense"), (.income, "Income"),
                                    (.savings, "Savings / Reserve")],
                          selection: $newGroupKind)
            }

            VStack(alignment: .leading, spacing: 4) {
                formLabel("Column")
                ZenSelect(options: [(0, "Left Column"), (1, "Right Column")], selection: $newGroupCol)
            }

            VStack(alignment: .leading, spacing: 4) {
                formLabel("Accent")
                HStack(spacing: 4) {
                    ForEach(Array(ZenGroupPalette.colors.prefix(6)), id: \.self) { c in
                        Button { newGroupColor = c } label: {
                            Circle().fill(Color(hexString: c))
                                .frame(width: 16, height: 16)
                                .padding(1)
                                .overlay {
                                    if newGroupColor == c { Circle().strokeBorder(Zen.ink, lineWidth: 2) }
                                }
                                .padding(-1)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(Zen.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            }

            Button { createGroup(mode: mode) } label: {
                HStack(spacing: 6) {
                    ZIcon("plus", size: 14)
                    Text("Add Group").fontWeight(.medium)
                }
            }
            .buttonStyle(.zen(.ink, padding: 16))
        }
        .zenCard(padding: 16)
    }

    /// Approximate width of the fixed controls next to the name field (selects, palette, button, gaps).
    private var formFixedWidth: CGFloat { 544 }

    private func formLabel(_ text: String) -> some View {
        Text(text).font(.zen(11)).foregroundStyle(Zen.ink2)
    }

    private func createGroup(mode: LedgerMode) {
        let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addGroup(mode: mode, name: name.uppercased(), kind: newGroupKind, column: newGroupCol,
                       color: newGroupColor)
        newGroupName = ""
    }

    // MARK: - Group card

    private func groupCard(_ grp: CategoryGroup, mode: LedgerMode, catalog: [CatalogGroupDef],
                           currency: String) -> some View {
        let cats = store.state.categories.filter { $0.groupId == grp.id }.sorted { $0.order < $1.order }
        let existing = Set(cats.map { $0.name.lowercased() })
        let catalogGroup = catalog.first { $0.id == grp.id || $0.name.lowercased() == grp.name.lowercased() }
        let suggestions = (catalogGroup?.items ?? []).filter { !existing.contains($0.name.lowercased()) }

        return VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ColorSwatchPicker(hex: grp.color) { store.updateGroup(grp.id, GroupPatch(color: $0)) }
                        .help("Change group color")
                    StudioTextField(value: grp.name, font: .zen(12, .semibold), tracking: 0.6, uppercase: true) {
                        store.updateGroup(grp.id, GroupPatch(name: $0))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Button {
                        store.updateGroup(grp.id, GroupPatch(column: grp.column == 0 ? 1 : 0))
                    } label: {
                        HStack(spacing: 4) {
                            ZIcon("arrow.left.arrow.right", size: 10)
                            Text(grp.column == 0 ? "Left Col" : "Right Col")
                        }
                    }
                    .buttonStyle(SmallChipStyle())
                    .help("Switch between Left and Right worksheet column")

                    Button {
                        let next = addingCatToGroup == grp.id ? nil : grp.id
                        addingCatToGroup = next
                    } label: {
                        ZIcon("plus", size: 14)
                    }
                    .buttonStyle(SmallChipStyle(padding: 4))
                    .help("Add subcategory")

                    ZenMiniButton(icon: "trash", size: 14, tint: Zen.ink3, hoverTint: Zen.accent, help: "Delete group") {
                        requestDelete(.group(id: grp.id, name: grp.name))
                    }
                }
                .fixedSize()
            }
            .padding(12)
            .background(Zen.raised.opacity(0.7))
            .overlay(alignment: .bottom) { Rectangle().fill(Zen.line).frame(height: 1) }

            // Categories
            VStack(spacing: 0) {
                ForEach(Array(cats.enumerated()), id: \.element.id) { idx, cat in
                    if idx > 0 { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
                    CategoryStudioRow(cat: cat, mode: mode, currency: currency) {
                        requestDelete(.category(id: cat.id, name: cat.name))
                    }
                }
            }

            // Suggestions
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ADDITIONAL CATEGORIES (CLICK TO ADD)")
                        .font(.zen(10))
                        .tracking(0.5)
                        .foregroundStyle(Zen.ink3)
                    FlowLayout(spacing: 4) {
                        ForEach(suggestions) { sug in
                            Button {
                                store.addCategory(groupId: grp.id, mode: mode, kind: grp.kind, name: sug.name,
                                                  defaultBudget: 0, taxRate: sug.taxRate ?? 0,
                                                  deductiblePct: sug.deductiblePct ?? (mode == .freelancer ? 100 : 0))
                            } label: {
                                HStack(spacing: 4) {
                                    ZIcon("plus", size: 12).foregroundStyle(Zen.ink3)
                                    Text(sug.name)
                                }
                            }
                            .buttonStyle(SuggestionChipStyle())
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Zen.app.opacity(0.6))
                .overlay(alignment: .top) { Rectangle().fill(Zen.line.opacity(0.6)).frame(height: 1) }
            }

            if addingCatToGroup == grp.id {
                AddCategoryForm(mode: mode, name: $catName, budget: $catBudget, tax: $catTax, ded: $catDed) {
                    createCategory(in: grp, mode: mode)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Zen.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Zen.line, lineWidth: 1))
    }

    private func createCategory(in grp: CategoryGroup, mode: LedgerMode) {
        let name = catName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let budget = NumberParsing.parse(catBudget) ?? 0
        let tax = NumberParsing.parse(catTax) ?? 0
        let dedParsed = NumberParsing.parse(catDed) ?? 0
        store.addCategory(groupId: grp.id, mode: mode, kind: grp.kind, name: name,
                          defaultBudget: budget.isNaN ? 0 : budget,
                          taxRate: mode == .freelancer ? tax : 0,
                          // parseFloat(catDed) || 100
                          deductiblePct: mode == .freelancer ? (dedParsed == 0 ? 100 : dedParsed) : 0)
        catName = ""
        catBudget = ""
        addingCatToGroup = nil
    }
}

// MARK: - Category row

private struct CategoryStudioRow: View {
    @Environment(LedgerStore.self) private var store
    let cat: CategoryItem
    let mode: LedgerMode
    let currency: String
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            StudioTextField(value: cat.name, font: .zen(12)) {
                store.updateCategory(cat.id, CategoryPatch(name: $0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                let recurring = cat.isRecurring ?? false
                RecurringToggle(isOn: recurring) { store.toggleCategoryRecurring(cat.id) }
                    .help(recurring ? "Recurring monthly item (click to disable)"
                                    : "Click to mark as recurring monthly item")

                HStack(spacing: 4) {
                    Text("Budget (\(currency)):").font(.zen(10)).foregroundStyle(Zen.ink3)
                    BoxNumberField(value: cat.defaultBudget, width: 80) {
                        store.updateCategory(cat.id, CategoryPatch(defaultBudget: $0))
                    }
                }

                if mode == .freelancer {
                    HStack(spacing: 4) {
                        Text("VAT%:").font(.zen(10)).foregroundStyle(Zen.ink3)
                        BoxNumberField(value: cat.taxRate ?? 0, width: 48) {
                            store.updateCategory(cat.id, CategoryPatch(taxRate: $0))
                        }
                    }
                    HStack(spacing: 4) {
                        Text("Ded%:").font(.zen(10)).foregroundStyle(Zen.ink3)
                        BoxNumberField(value: cat.deductiblePct ?? 100, width: 48) {
                            store.updateCategory(cat.id, CategoryPatch(deductiblePct: $0))
                        }
                    }
                }

                ZenMiniButton(icon: "trash", size: 14, tint: Zen.ink3, hoverTint: Zen.accent,
                              help: "Remove category", action: onDelete)
            }
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? Zen.raised.opacity(0.4) : .clear)
        .onHover { hovering = $0 }
    }
}

private struct RecurringToggle: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZIcon("repeat", size: 12, weight: isOn ? .medium : .light)
                .foregroundStyle(isOn ? Zen.indigo : (hovering ? Zen.indigo : Zen.ink3))
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(isOn ? Zen.indigo.opacity(0.15) : Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(isOn ? Zen.indigo.opacity(0.3) : Zen.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Add category inline form

private struct AddCategoryForm: View {
    let mode: LedgerMode
    @Binding var name: String
    @Binding var budget: String
    @Binding var tax: String
    @Binding var ded: String
    let onSubmit: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $name, prompt: Text("Custom category name…").foregroundStyle(Zen.ink3))
                .boxField(height: 28)
                .frame(minWidth: 140, maxWidth: .infinity)
                .focused($nameFocused)
                .onSubmit(onSubmit)
            TextField("", text: $budget, prompt: Text("Default Budget").foregroundStyle(Zen.ink3))
                .boxField(height: 28, trailing: true)
                .frame(width: 96)
                .onSubmit(onSubmit)
            if mode == .freelancer {
                TextField("", text: $tax, prompt: Text("VAT %").foregroundStyle(Zen.ink3))
                    .boxField(height: 28, trailing: true)
                    .frame(width: 64)
                    .onSubmit(onSubmit)
                TextField("", text: $ded, prompt: Text("Ded %").foregroundStyle(Zen.ink3))
                    .boxField(height: 28, trailing: true)
                    .frame(width: 64)
                    .onSubmit(onSubmit)
            }
            Button(action: onSubmit) {
                HStack(spacing: 4) {
                    ZIcon("checkmark", size: 12)
                    Text("Add")
                }
            }
            .buttonStyle(.zen(.ink, height: 28, radius: 4, padding: 10))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Zen.app)
        .overlay(alignment: .top) { Rectangle().fill(Zen.line).frame(height: 1) }
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }
}

// MARK: - Controls

private extension View {
    /// h-7 px-2 rounded bg-surface border border-line text-xs (inline add form inputs).
    func boxField(height: CGFloat, trailing: Bool = false, background: Color = Zen.surface,
                  padding: CGFloat = 8) -> some View {
        self.textFieldStyle(.plain)
            .font(.zen(12))
            .monospacedDigit()
            .multilineTextAlignment(trailing ? .trailing : .leading)
            .foregroundStyle(Zen.ink)
            .padding(.horizontal, padding)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
    }
}

/// `<input type="number">` bound to a ledger value (h-6 rounded bg-raised border-line, right aligned).
/// Every edit is committed (parseFloat(...) || 0), like the Windows onChange handler.
private struct BoxNumberField: View {
    let value: Double
    let width: CGFloat
    let onChange: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .boxField(height: 24, trailing: true, background: Zen.raised, padding: 6)
            .frame(width: width)
            .focused($focused)
            .onAppear { text = Self.format(value) }
            .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
            .onChange(of: text) { _, t in
                guard focused else { return }
                let parsed = NumberParsing.parse(t) ?? 0
                if parsed != value { onChange(parsed) }
            }
            .onChange(of: focused) { _, f in if !f { text = Self.format(value) } }
            .onSubmit { focused = false }
    }

    /// Number input shows the raw value ("0" for zero).
    static func format(_ v: Double) -> String {
        let s = NumberParsing.editable(v)
        return s.isEmpty ? "0" : s
    }
}

/// Transparent text input that gets a surface background while focused (group / category names).
private struct StudioTextField: View {
    let value: String
    var font: Font = .zen(12)
    var tracking: CGFloat = 0
    var uppercase = false
    let onChange: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .tracking(tracking)
            .foregroundStyle(Zen.ink)
            .lineLimit(1)
            .padding(.horizontal, focused ? 6 : 0)
            .opacity(focused ? 1 : 0)
            .overlay(alignment: .leading) {
                if !focused {
                    Text(uppercase ? text.uppercased() : text)
                        .font(font)
                        .tracking(tracking)
                        .foregroundStyle(Zen.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .allowsHitTesting(false)
                }
            }
            .background(focused ? Zen.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
            .onChange(of: text) { _, t in if focused && t != value { onChange(t) } }
            .onSubmit { focused = false }
    }
}

/// px-2 py-0.5 rounded bg-surface border border-line text-[10px] text-ink-2 hover:text-ink.
private struct SmallChipStyle: ButtonStyle {
    var padding: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration, padding: padding)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        let padding: CGFloat?
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.zen(10))
                .foregroundStyle(hovering ? Zen.ink : Zen.ink2)
                .padding(.horizontal, padding ?? 8)
                .padding(.vertical, padding ?? 2)
                .background(Zen.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Zen.line, lineWidth: 1))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// h-6 px-2 rounded-md border border-dashed border-line hover:border-ink-2 text-[11px].
private struct SuggestionChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ChipBody(configuration: configuration) }

    private struct ChipBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.zen(11))
                .foregroundStyle(hovering ? Zen.ink : Zen.ink2)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(hovering ? Zen.ink2 : Zen.line, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// `<input type="color">`: a 20 px swatch that opens the system color panel.
private struct ColorSwatchPicker: View {
    let hex: String
    let onChange: (String) -> Void

    var body: some View {
        Button {
            ColorPanelBridge.shared.open(hex: hex, onChange: onChange)
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hexString: hex))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
private final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((String) -> Void)?

    func open(hex: String, onChange: @escaping (String) -> Void) {
        let panel = NSColorPanel.shared
        // Detach first so setting the initial color does not fire the previous callback.
        panel.setTarget(nil)
        panel.setAction(nil)
        self.onChange = onChange
        panel.showsAlpha = false
        panel.isContinuous = true
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        panel.color = NSColor(hex: UInt32(cleaned, radix: 16) ?? 0x7A746B)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let c = sender.color.usingColorSpace(.sRGB) else { return }
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()),
            b = Int((c.blueComponent * 255).rounded())
        onChange?(String(format: "#%02x%02x%02x", r, g, b))
    }
}
