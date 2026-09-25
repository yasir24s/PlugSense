import AppKit
import SwiftUI
import PlugSenseKit

/// What the popup is showing: one row per port, newest last.
@MainActor
final class PopupModel: ObservableObject {
    struct Item: Identifiable {
        enum Style {
            case news(PlugWatcher.Event.Kind)
            /// "Use this connection for… Charge + data / Data only".
            case question
            /// The device started charging although the user chose Data only.
            case chargingWarning
        }

        var id: PortID { verdict.port }
        var style: Style
        var verdict: PortVerdict
        var previous: PortVerdict?
        var choice: ConnectionChoice?
        var expires: Date

        var isQuestion: Bool {
            switch style {
            case .question: true
            default: false
            }
        }

        var isUnplugged: Bool {
            switch style {
            case .news(.detached): true
            default: false
            }
        }

        /// An unplugged port shows what it was.
        var shown: PortVerdict { isUnplugged ? previous ?? verdict : verdict }

        var headline: String {
            switch style {
            case .question, .news(.attached): "Plugged in"
            case .chargingWarning: "Charging"
            case .news(.changed) where previous.map(verdict.finishedCharging) ?? false: "Finished charging"
            case .news(.changed): "Changed"
            case .news(.detached): "Unplugged"
            }
        }
    }

    @Published var items: [Item] = []
    var hovering = false
}

struct PopupView: View {
    @ObservedObject var popup: PopupModel
    /// ImageRenderer can't draw materials, so --render uses a solid fill.
    var rendering = false
    var onOpen: (PortID) -> Void = { _ in }
    var onChoose: (PortVerdict, ConnectionChoice) -> Void = { _, _ in }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(popup.items) { item in row(item) }
        }
        .padding(10)
        .frame(width: 360)
        .background {
            if rendering { shape.fill(Color(nsColor: .windowBackgroundColor)) } else { shape.fill(.regularMaterial) }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        .onHover { popup.hovering = $0 }
    }

    private func row(_ item: PopupModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(item.headline) · \(item.verdict.port.description)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            PortCard(verdict: item.shown, expandable: false, choice: item.choice)
                .opacity(item.isUnplugged ? 0.55 : 1)
            switch item.style {
            case .question:
                ChargeOrDataQuestion { onChoose(item.verdict, $0) }
            case .chargingWarning:
                Text(chargingWarning(item.verdict))
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            case .news:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !item.isQuestion { onOpen(item.id) } }   // a question waits for its answer
    }

    private func chargingWarning(_ v: PortVerdict) -> String {
        let level = v.batteryPercent.map { " (\($0)%)" } ?? ""
        let advice = v.deviceKey?.hasPrefix("apple:iPhone") == true
            ? "Unplug when you're done, or set its Charge Limit: Settings › Battery › Charging."
            : "Unplug when you're done."
        return "\(v.title) is charging\(level). \(advice)"
    }
}

/// "Use this connection for…": asked once per device. The buttons are drawn by SwiftUI rather than
/// AppKit, so they take the first click in a panel that isn't key (and ImageRenderer can draw them).
struct ChargeOrDataQuestion: View {
    let choose: (ConnectionChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Use this connection for…").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                answer("Charge + data", filled: false) { choose(.chargeAndData) }
                answer("Data only", filled: true) { choose(.dataOnly) }
            }
            Text("Data only can't turn the power off — I'll tell you if it starts charging.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4)
    }

    private func answer(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(filled ? Color.white : Color.primary)
                .background(filled ? Color.accentColor : Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A borderless, non-activating panel under the menu bar item. It takes clicks without making
/// PlugSense the active app, so plugging in a cable never steals the keyboard.
@MainActor
final class PopupController {
    var onOpen: ((PortID) -> Void)?
    var onChoose: ((PortVerdict, ConnectionChoice) -> Void)?
    private let model = PopupModel()
    private var panel: NSPanel?
    private var anchor: NSRect?
    private var timer: Timer?
    private var generation = 0

    func isShowing(_ port: PortID) -> Bool { model.items.contains { $0.id == port } }
    func isAsking(_ port: PortID) -> Bool { model.items.contains { $0.id == port && $0.isQuestion } }

    /// Plug, unplug and change news.
    func show(_ event: PlugWatcher.Event, choice: ConnectionChoice?, under anchor: NSRect?) {
        let existing = model.items.first { $0.id == event.verdict.port }
        // A row that is asking keeps asking; a "Plugged in" row stays "Plugged in" as its verdict firms up.
        let style: PopupModel.Item.Style = switch (existing?.style, event.kind) {
        case (.question?, _): .question
        case (.news(.attached)?, .changed): .news(.attached)
        default: .news(event.kind)
        }
        upsert(.init(style: style, verdict: event.verdict, previous: event.previous ?? existing?.previous,
                     choice: choice, expires: Date().addingTimeInterval(event.kind == .detached ? 4 : 7)),
               under: anchor)
    }

    /// "Use this connection for…". Stays up longer than news: it is waiting for an answer.
    func ask(about verdict: PortVerdict, under anchor: NSRect?) {
        upsert(.init(style: .question, verdict: verdict, previous: nil, choice: nil,
                     expires: Date().addingTimeInterval(30)), under: anchor)
    }

    func warnCharging(_ verdict: PortVerdict, under anchor: NSRect?) {
        upsert(.init(style: .chargingWarning, verdict: verdict, previous: nil, choice: .dataOnly,
                     expires: Date().addingTimeInterval(12)), under: anchor)
    }

    /// Turns an answered question into a brief "Plugged in" row that shows the choice.
    func acknowledge(_ verdict: PortVerdict, choice: ConnectionChoice) {
        upsert(.init(style: .news(.attached), verdict: verdict, previous: nil, choice: choice,
                     expires: Date().addingTimeInterval(3)), under: nil)
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        generation += 1
        let current = generation
        guard let panel, panel.isVisible else {
            model.items = []
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }   // a new row arrived mid-fade
                self.panel?.orderOut(nil)
                self.model.items = []
            }
        })
    }

    private func upsert(_ item: PopupModel.Item, under anchor: NSRect?) {
        if let anchor { self.anchor = anchor }
        if let i = model.items.firstIndex(where: { $0.id == item.id }) {
            var item = item
            if item.isQuestion { item.expires = max(item.expires, model.items[i].expires) }
            model.items[i] = item
        } else {
            model.items.append(item)
            if model.items.count > 3 { model.items.removeFirst() }
        }
        present()
    }

    private func present() {
        generation += 1
        let panel = self.panel ?? makePanel()
        layout()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.layout() }   // SwiftUI sizes new rows a tick later
        }
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.expire() }
            }
        }
    }

    private func expire() {
        let now = Date()
        if model.hovering {   // being read: keep everything a little longer
            for i in model.items.indices {
                model.items[i].expires = max(model.items[i].expires, now.addingTimeInterval(2))
            }
            return
        }
        let remaining = model.items.filter { $0.expires > now }
        if remaining.isEmpty {
            dismiss()
        } else if remaining.count != model.items.count {
            model.items = remaining
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.layout() } }
        }
    }

    private func layout() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        let screen = NSScreen.screens.first { screen in anchor.map { screen.frame.intersects($0) } ?? false }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let under = anchor ?? NSRect(x: visible.maxX - 40, y: visible.maxY, width: 0, height: 0)
        let x = min(max(under.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let y = min(under.minY, visible.maxY) - size.height - 6
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    private func makePanel() -> NSPanel {
        let view = PopupView(popup: model,
                             onOpen: { [weak self] port in self?.onOpen?(port) },
                             onChoose: { [weak self] verdict, choice in self?.onChoose?(verdict, choice) })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = FirstClickHostingView(rootView: view)
        self.panel = panel
        return panel
    }
}

/// Lets a click on the popup act immediately, instead of first bringing its window forward.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
