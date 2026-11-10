import AppKit
import SwiftUI

@main
struct KobanApp: App {
    @State private var store = LedgerStore()

    var body: some Scene {
        WindowGroup("Koban") {
            RootView()
                .environment(store)
                .frame(minWidth: 1024, minHeight: 640)
                .task {
                    store.bootstrap()
                    #if DEBUG
                    DebugSnapshot.runIfRequested(store: store)
                    #endif
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.flushPendingSave()
                }
        }
        // The Windows build draws its own 48 px top bar; the title bar is hidden so it can do the same.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 880)
        .commands { KobanCommands(store: store) }
    }
}

/// Menu bar commands. Same shortcuts as the Windows build with ⌘ in place of Ctrl:
/// ⌘B sidebar, ⌘S backup, ⌘N add entry, ⌘L lock, and plain 1–9 / 0 to switch views.
struct KobanCommands: Commands {
    let store: LedgerStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Entry") { store.openQuickAdd() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!store.isUnlockedAndReady)
        }
        CommandGroup(after: .newItem) {
            Button("Import Data…") { store.openImport() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!store.isUnlockedAndReady)
            Menu("Export") {
                Button("Excel Workbook (.xlsx)…") { store.exportExcel() }
                Button("Monthly Budget CSV…") { store.exportBudgetCSV() }
                Button("Transactions & Tax CSV…") { store.exportTransactionsCSV() }
            }
            .disabled(!store.isUnlockedAndReady)
            Divider()
            Button("Re-run Setup / Change Mode…") { store.openSetupWizard() }
                .disabled(!store.isUnlockedAndReady)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Backup Encrypted DB Now") { store.manualBackup() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!store.isUnlockedAndReady)
        }

        CommandGroup(before: .sidebar) {
            Button(store.isSidebarOpen ? "Hide Sidebar" : "Show Sidebar") { store.toggleSidebar() }
                .keyboardShortcut("b", modifiers: .command)
            Divider()
            ForEach(Array(ViewTab.allCases.enumerated()), id: \.element) { idx, tab in
                Button(tab.title) { store.selectedTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String((idx + 1) % 10))), modifiers: .command)
            }
            Divider()
            Button("Cycle Theme (System / Light / Dark)") { store.cycleTheme() }
            Divider()
        }

        CommandMenu("Ledger") {
            Button("Previous Month") { store.shiftMonth(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!store.isUnlockedAndReady)
            Button("Next Month") { store.shiftMonth(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!store.isUnlockedAndReady)

            Divider()

            ForEach(Array(ActiveWorkspace.allCases.enumerated()), id: \.element) { idx, ws in
                Button(ws.title) { store.setWorkspace(ws) }
                    .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: [.command, .option])
                    .disabled(!store.isUnlockedAndReady)
            }

            Divider()

            Button("Lock Vault") { store.lockVault() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!store.isUnlockedAndReady)
        }
    }
}

/// Plain digit keys switch views when no text field has focus (tabMap in App.tsx).
@MainActor
enum DigitKeyNavigation {
    private static var monitor: Any?

    static func install(store: LedgerStore) {
        guard monitor == nil else { return }
        let tabs: [String: ViewTab] = ["1": .worksheet, "2": .yearlyPlanner, "3": .transactions, "4": .accounts,
                                       "5": .reports, "6": .categories, "7": .recurring, "8": .goals,
                                       "9": .backups, "0": .settings]
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard store.isReady,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, let tab = tabs[chars],
                  !(event.window?.firstResponder is NSText) else { return event }
            store.selectedTab = tab
            store.openMenu = nil
            return nil
        }
    }
}

/// Posted in debug builds when KOBAN_SNAPSHOT_ACTION is set (no-op in release).
extension Notification.Name {
    static let kobanDebugAction = Notification.Name("KobanDebugAction")
}

#if DEBUG
/// Developer aid: KOBAN_PERF=/path/out.txt measures tab switches and scroll steps (synchronous
/// layout + display of the window) and writes the timings, then quits.
@MainActor
enum PerfProbe {
    static func run(store: LedgerStore, output: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { exit(2) }
            window.setContentSize(NSSize(width: 1360, height: 880))
            NSApp.activate(ignoringOtherApps: true)
            window.level = .floating
            window.orderFrontRegardless()
            window.makeKey()
            try? await Task.sleep(for: .seconds(1))
            var lines: [String] = []
            store.isAppLocked = false
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("visible: \(window.occlusionState.contains(.visible)) key: \(window.isKeyWindow)")
            lines.append("phase: \(store.phase) appLocked: \(store.isAppLocked) tab: \(store.selectedTab.rawValue)")
            /// Main-thread CPU time (ms). Work done on the main thread is what makes the UI lag.
            @MainActor func cpu() -> Double {
                var info = thread_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
                let thread = mach_thread_self()
                defer { mach_port_deallocate(mach_task_self_, thread) }
                _ = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                    }
                }
                let user = Double(info.user_time.seconds) * 1000 + Double(info.user_time.microseconds) / 1000
                let sys = Double(info.system_time.seconds) * 1000 + Double(info.system_time.microseconds) / 1000
                return user + sys
            }
            /// Runs `action`, lets the app render for `window` ms, returns main-thread CPU spent.
            @MainActor func work(_ settleMs: Int = 700, _ action: () -> Void) async -> Double {
                let c0 = cpu()
                action()
                try? await Task.sleep(for: .milliseconds(settleMs))
                return cpu() - c0
            }
            _ = await work {}
            @MainActor func measureTab(_ tab: ViewTab) async -> Double {
                await work { store.selectedTab = tab }
            }
            if let mode = ProcessInfo.processInfo.environment["KOBAN_PERF_LOOP"], mode.hasPrefix("scroll") {
                store.selectedTab = mode == "scroll-yearly" ? .yearlyPlanner : .worksheet
                try? await Task.sleep(for: .milliseconds(500))
                guard let scroll = largestScrollView(in: window.contentView) else { exit(3) }
                let end = Date().addingTimeInterval(12)
                var y: CGFloat = 0, dir: CGFloat = 40
                while Date() < end {
                    y += dir
                    if y > 3000 || y < 0 { dir = -dir }
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    try? await Task.sleep(for: .milliseconds(16))
                }
                exit(0)
            }
            if ProcessInfo.processInfo.environment["KOBAN_PERF_LOOP"] != nil {
                // Profiling loop: alternate Monthly Budget / Yearly Planner for 12 s.
                let end = Date().addingTimeInterval(12)
                var flip = false
                while Date() < end {
                    store.selectedTab = flip ? .worksheet : .yearlyPlanner
                    flip.toggle()
                    try? await Task.sleep(for: .milliseconds(150))
                }
                exit(0)
            }
            let idle = await work {}
            lines.append(String(format: "idle (700 ms window) %.1f ms CPU", idle))
            let tabs: [ViewTab] = [.worksheet, .yearlyPlanner, .transactions, .reports, .accounts]
            for round in 0..<3 {
                for tab in tabs {
                    let ms = await measureTab(tab)
                    lines.append(String(format: "switch r%d %@ %.1f ms CPU", round, tab.rawValue, ms))
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            for tab in [ViewTab.worksheet, .yearlyPlanner] {
                _ = await measureTab(tab)
                try? await Task.sleep(for: .milliseconds(200))
                guard let scroll = largestScrollView(in: window.contentView) else { continue }
                // Scroll the whole document in 40 pt steps; each step is laid out and drawn
                // synchronously so its main-thread cost can be attributed to that frame.
                let docHeight = scroll.documentView?.frame.height ?? 0
                let maxY = min(20000, max(0, docHeight - scroll.contentView.bounds.height))
                var steps: [Double] = []
                for pass in 0..<2 {
                    var y: CGFloat = pass == 0 ? 0 : maxY
                    while pass == 0 ? y < maxY : y > 0 {
                        y += pass == 0 ? 40 : -40
                        let c0 = cpu()
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(y, 0), maxY)))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        window.contentView?.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        CATransaction.flush()
                        steps.append(cpu() - c0)
                        try? await Task.sleep(for: .milliseconds(16))
                    }
                }
                let sorted = steps.sorted()
                func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                lines.append(String(format: "scroll %@ (doc %.0f pt, %d steps): median %.1f ms, p95 %.1f ms, max %.1f ms, >16ms: %d",
                                    tab.rawValue, docHeight, steps.count, pct(0.5), pct(0.95), sorted.last ?? 0,
                                    steps.filter { $0 > 16 }.count))
            }
            // Typing a budget value: one store update + re-render.
            let catId = store.state.categories.first?.id ?? ""
            _ = await measureTab(.worksheet)
            var edits: [Double] = []
            for i in 0..<10 {
                edits.append(await work(400) { store.setBudget(Double(100 + i), categoryId: catId) })
            }
            lines.append(String(format: "edit budget median %.1f ms CPU", edits.sorted()[5]))
            try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    private static func largestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView, s.frame.width > 600,
               (best == nil || s.documentView?.frame.height ?? 0 > best?.documentView?.frame.height ?? 0) { best = s }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }
}

/// Developer aid: KOBAN_SNAPSHOT=/path/out.png renders the window to a PNG and quits.
/// Optional KOBAN_SNAPSHOT_THEME=light|dark, KOBAN_SNAPSHOT_MENU=month|export, KOBAN_SNAPSHOT_TAB=<ViewTab raw>.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(store: LedgerStore) {
        let env = ProcessInfo.processInfo.environment
        if let perfOut = env["KOBAN_PERF"] { PerfProbe.run(store: store, output: perfOut); return }
        guard let out = env["KOBAN_SNAPSHOT"] else { return }
        if let theme = env["KOBAN_SNAPSHOT_THEME"] {
            NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        }
        if let ws = env["KOBAN_SNAPSHOT_WORKSPACE"].flatMap(ActiveWorkspace.init(rawValue:)) {
            store.state.settings.activeWorkspace = ws
        }
        if let tab = env["KOBAN_SNAPSHOT_TAB"].flatMap(ViewTab.init(rawValue:)) { store.selectedTab = tab }
        switch env["KOBAN_SNAPSHOT_MENU"] {
        case "month": store.openMenu = .month
        case "export": store.openMenu = .export
        default: break
        }
        if env["KOBAN_SNAPSHOT_TOAST"] != nil { store.notify("Signed in as Koban Owner.") }
        // Features can react to KOBAN_SNAPSHOT_ACTION=<name> (open a modal, switch a sub-tab …):
        //   .onReceive(NotificationCenter.default.publisher(for: .kobanDebugAction)) { … }
        if let action = env["KOBAN_SNAPSHOT_ACTION"] {
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                NotificationCenter.default.post(name: .kobanDebugAction, object: nil, userInfo: ["name": action])
            }
        }
        Task {
            let delay = Double(env["KOBAN_SNAPSHOT_DELAY"] ?? "") ?? 1.5
            try? await Task.sleep(for: .seconds(delay))
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let view = window.contentView?.superview ?? window.contentView else { exit(2) }
            window.setContentSize(NSSize(width: 1360, height: 880))
            try? await Task.sleep(for: .seconds(0.6))
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { exit(3) }
            view.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }
}
#endif
