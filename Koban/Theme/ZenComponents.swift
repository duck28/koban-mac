import AppKit
import SwiftUI

// Reusable pieces that reproduce the Tailwind classes of the Windows build
// (h-8 px-3 rounded-lg border border-line bg-surface …).

// MARK: - Buttons

enum ZenButtonKind {
    /// iconBtn in TopBar.tsx: transparent, raised on hover.
    case icon
    /// Outline: bg-surface border-line, raised on hover.
    case outline
    /// Primary: bg-ink text-on-ink.
    case ink
    /// Filled raised (TopBar "Add Entry").
    case raised
    /// No chrome, raised on hover (menus, list rows).
    case ghost
}

struct ZenButtonStyle: ButtonStyle {
    var kind: ZenButtonKind = .outline
    var height: CGFloat = 32
    var radius: CGFloat = 8
    var horizontalPadding: CGFloat = 12
    var fontSize: CGFloat = 12
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        ZenButtonBody(configuration: configuration, style: self)
    }
}

private struct ZenButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let style: ZenButtonStyle
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.zen(style.fontSize))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, style.horizontalPadding)
            .frame(minWidth: style.kind == .icon ? style.height : nil, minHeight: style.height)
            .frame(height: style.height)
            .background(background, in: RoundedRectangle(cornerRadius: style.radius))
            .overlay {
                if style.kind == .outline {
                    RoundedRectangle(cornerRadius: style.radius).strokeBorder(Zen.line, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (style.kind == .ink && (hovering || configuration.isPressed) ? 0.85 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: style.radius))
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch style.kind {
        case .ink: return Zen.onInk
        case .raised: return Zen.ink
        case .icon, .ghost, .outline: return (hovering || style.active) ? Zen.ink : Zen.ink2
        }
    }

    private var background: Color {
        switch style.kind {
        case .ink: return Zen.ink
        case .raised: return hovering ? Zen.line.opacity(0.7) : Zen.raised
        case .outline: return hovering ? Zen.raised : Zen.surface
        case .icon, .ghost: return (hovering || style.active || configuration.isPressed) ? Zen.raised : .clear
        }
    }
}

extension ButtonStyle where Self == ZenButtonStyle {
    static var zenIcon: ZenButtonStyle { ZenButtonStyle(kind: .icon, radius: 6, horizontalPadding: 6) }
    static var zenOutline: ZenButtonStyle { ZenButtonStyle(kind: .outline) }
    static var zenInk: ZenButtonStyle { ZenButtonStyle(kind: .ink) }
    static func zen(_ kind: ZenButtonKind, height: CGFloat = 32, radius: CGFloat = 8,
                    padding: CGFloat = 12, fontSize: CGFloat = 12, active: Bool = false) -> ZenButtonStyle {
        ZenButtonStyle(kind: kind, height: height, radius: radius, horizontalPadding: padding,
                       fontSize: fontSize, active: active)
    }
}

/// Small square hover button used inside cards (p-1 rounded, w-3 / w-3.5 icons).
struct ZenMiniButton: View {
    let icon: String
    var size: CGFloat = 12
    var tint: Color = Zen.ink3
    var hoverTint: Color = Zen.ink
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZIcon(icon, size: size, weight: .regular)
                .foregroundStyle(hovering ? hoverTint : tint)
                .padding(4)
                .background(hovering ? Zen.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Fields

struct ZenFieldStyle: ViewModifier {
    var height: CGFloat = 32
    var background: Color = Zen.raised
    var fontSize: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.zen(fontSize))
            .foregroundStyle(Zen.ink)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
    }
}

extension View {
    func zenField(height: CGFloat = 32, background: Color = Zen.raised, fontSize: CGFloat = 12) -> some View {
        modifier(ZenFieldStyle(height: height, background: background, fontSize: fontSize))
    }

    /// bg-surface border border-line rounded-xl
    func zenCard(padding: CGFloat = 14, radius: CGFloat = 12) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Zen.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1))
    }

    /// Floating panel used by dropdown menus and modals (rounded-xl, soft shadow).
    func zenPanel(radius: CGFloat = 12) -> some View {
        background(Zen.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Zen.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
    }
}

/// Native picker restyled like the Windows <select> (h-8 rounded-lg bg-raised border-line).
struct ZenSelect<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var background: Color = Zen.raised

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    if value == selection { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first(where: { $0.0 == selection })?.1 ?? "")
                    .font(.zen(12)).foregroundStyle(Zen.ink).lineLimit(1)
                Spacer(minLength: 4)
                ZIcon("chevron.down", size: 12).foregroundStyle(Zen.ink3)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Zen.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Square Zen checkbox (rounded border-line).
struct ZenCheckbox: View {
    @Binding var isOn: Bool
    let label: String
    var fontSize: CGFloat = 12
    var color: Color = Zen.ink2

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isOn ? Zen.ink : Zen.surface)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(isOn ? Zen.ink : Zen.ink3, lineWidth: 1))
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Zen.onInk)
                        }
                    }
                    .frame(width: 13, height: 13)
                Text(label).font(.zen(fontSize)).foregroundStyle(color).multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Labels

/// text-[10px] uppercase tracking-[0.12em] text-ink-3
struct ZenEyebrow: View {
    let text: String
    var tracking: CGFloat = 1.2

    init(_ text: String, tracking: CGFloat = 1.2) {
        self.text = text
        self.tracking = tracking
    }

    var body: some View {
        Text(text.uppercased())
            .font(.zen(10))
            .tracking(tracking)
            .foregroundStyle(Zen.ink3)
    }
}

// MARK: - Logo

/// The "K Koban" lockup from src/assets (koban-full-light / -dark), switching with the appearance.
struct KobanLogo: View {
    var height: CGFloat = 20
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = KobanLogo.image(colorScheme == .dark ? "koban-full-dark" : "koban-full-light") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .accessibilityLabel("Koban")
        } else {
            Text("Koban").font(.system(size: height * 0.9, weight: .semibold)).foregroundStyle(Zen.ink)
        }
    }

    static func image(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

// MARK: - Toast

struct ZenToast: View {
    let message: String
    var filePath: String?
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZIcon("checkmark.circle", size: 16).foregroundStyle(Zen.positive)
            Text(message).font(.zen(12)).foregroundStyle(Zen.ink).lineLimit(2)
            if let filePath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                } label: {
                    HStack(spacing: 4) {
                        Text("Reveal")
                        ZIcon("arrow.up.right.square", size: 12)
                    }
                    .font(.zen(12))
                    .foregroundStyle(Zen.ink2)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Zen.raised, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(filePath)
            }
            ZenMiniButton(icon: "xmark", size: 14, action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .zenPanel()
    }
}

// MARK: - Modal

/// Centered modal over a dimmed backdrop (fixed inset-0 bg-black/55 … max-w-md rounded-2xl).
struct ZenModal<Content: View>: View {
    let onDismiss: () -> Void
    /// nil lets the content size itself (use .frame(width:) inside).
    var width: CGFloat? = 448
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            content()
                .frame(width: width)
                .zenPanel(radius: 16)
                .padding(24)
                .onExitCommand(perform: onDismiss)
        }
        .transition(.opacity)
    }
}

// MARK: - Window chrome

/// Lets the custom top bar act as the title bar: drag to move, double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}

/// Configures the hosting NSWindow: transparent title bar, and traffic lights vertically
/// centered in the 48 pt top bar (they sit at the standard 28 pt title bar height otherwise).
struct WindowConfigurator: NSViewRepresentable {
    var barHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.barHeight = barHeight
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProbeView)?.barHeight = barHeight
    }

    final class ProbeView: NSView {
        var barHeight: CGFloat = 48 { didSet { relayout() } }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarSeparatorStyle = .none
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                                              NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didResignKeyNotification, NSWindow.didChangeScreenNotification]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.relayout() }
                })
            }
            DispatchQueue.main.async { self.relayout() }
        }

        func relayout() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let titlebar = close.superview,
                  let container = titlebar.superview else { return }
            var frame = container.frame
            frame.size.height = barHeight
            frame.origin.y = window.frame.height - barHeight
            container.frame = frame
            titlebar.frame = container.bounds

            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { window.standardWindowButton($0) }
            let spacing: CGFloat = 20
            for (i, button) in buttons.enumerated() {
                button.setFrameOrigin(NSPoint(x: 16 + CGFloat(i) * spacing,
                                              y: ((barHeight - button.frame.height) / 2).rounded()))
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
