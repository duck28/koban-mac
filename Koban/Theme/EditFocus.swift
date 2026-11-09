import AppKit
import SwiftUI

/// Click-to-edit support for large editable grids (Monthly Budget, Yearly Planner).
///
/// A SwiftUI TextField is backed by an NSTextField that is expensive to create and lay out.
/// Grids with hundreds of always-live fields made tab switches and scrolling slow, so cells now
/// render as plain Text and only the cell being edited becomes a real TextField.
/// `EditFocus` tracks that cell and provides Tab / Shift-Tab navigation in grid order (the
/// windows' field-to-field tabbing), which no longer works natively because neighbours aren't
/// text fields until they are activated.
@MainActor
@Observable
final class EditFocus {
    /// The cell currently shown as a TextField (nil = none).
    var active: String? {
        didSet { if active != nil { installMonitorIfNeeded() } }
    }
    /// Tab order of all cells, set by the owning view while rendering.
    @ObservationIgnored var order: [String] = []
    /// Called when Tab moves to a cell (e.g. to scroll it into view).
    @ObservationIgnored var onMove: ((String) -> Void)?

    @ObservationIgnored nonisolated(unsafe) private var monitor: Any?

    /// Kept cheap: @State re-evaluates this initializer on every parent render (only the first
    /// instance is kept), so the key monitor is installed lazily on first edit.
    init() {}

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48, // Tab
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let backwards = event.modifierFlags.contains(.shift)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let current = self.active,
                      let next = self.neighbour(of: current, backwards: backwards) else { return false }
                self.active = next
                self.onMove?(next)
                return true
            }
            return handled ? nil : event
        }
    }

    // Lives for the lifetime of the owning view (@State); the monitor goes with it.
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    func neighbour(of id: String, backwards: Bool) -> String? {
        guard let idx = order.firstIndex(of: id) else { return nil }
        let next = backwards ? idx - 1 : idx + 1
        return order.indices.contains(next) ? order[next] : nil
    }

    /// The editor lost focus (click elsewhere, Return, Esc): stop editing that cell.
    func end(_ id: String) {
        if active == id { active = nil }
    }
}
