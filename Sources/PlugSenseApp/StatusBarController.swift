import AppKit
import SwiftUI
import PlugSenseKit

/// The menu bar item, its popover, and the popup that appears on plug events.
@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let popup = PopupController()
    /// Ports plugged in lately whose device hasn't been asked "charge or data?" yet, with when.
    private var askable: [PortID: Date] = [:]

    init(model: AppModel) {
        self.model = model
        super.init()
        let content = NSHostingController(rootView: PopoverView(model: model))
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content
        popover.behavior = .transient
        item.button?.image = symbol("cable.connector")
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        model.onVerdicts = { [weak self] verdicts in self?.updateIcon(verdicts) }
        model.onEvent = { [weak self] event in self?.handle(event) }
        popup.onOpen = { [weak self] port in self?.showPopover(focusing: port) }
        popup.onChoose = { [weak self] verdict, choice in self?.chose(choice, for: verdict) }
    }

    private var anchor: NSRect? { item.button?.window?.frame }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover(focusing: nil) }
    }

    private func showPopover(focusing port: PortID?) {
        guard let button = item.button else { return }
        popup.dismiss()
        if let port { model.expanded = [port] }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func handle(_ event: PlugWatcher.Event) {
        let now = event.verdict
        switch event.kind {
        case .attached: askable[now.port] = Date()
        case .detached: askable[now.port] = nil
        case .changed: break
        }
        guard model.popUpOnPlug, !popover.isShown else { return }
        let choice = model.choice(for: now)

        // Ask once per plug-in, as soon as it is known whether the device is charging. An iPhone's own
        // battery report arrives a moment after it enumerates, so this is often a "changed" event.
        if let pluggedAt = askable[now.port], now.canAskChargeOrData {
            askable[now.port] = nil
            if choice == nil, Date().timeIntervalSince(pluggedAt) < 60 {
                return popup.ask(about: now, under: anchor)
            }
        }
        // Data only can't be enforced, so keep the other half of the promise: say when it charges.
        if choice == .dataOnly, now.charge == .charging, event.previous?.charge != .charging {
            return popup.warnCharging(now, under: anchor)
        }
        if popup.isAsking(now.port) || worthPoppingUp(event) {
            popup.show(event, choice: choice, under: anchor)
        }
    }

    private func chose(_ choice: ConnectionChoice, for verdict: PortVerdict) {
        guard let key = verdict.deviceKey else { return }
        model.setChoice(choice, for: key)
        let current = model.verdicts.first { $0.port == verdict.port } ?? verdict
        if choice == .dataOnly, current.charge == .charging {
            popup.warnCharging(current, under: anchor)
        } else {
            popup.acknowledge(current, choice: choice)
        }
    }

    /// Plugging and unplugging always pop up. A change pops up when a link came or went, or when a
    /// battery itself reports it has stopped charging. Inferred charge changes (meter drift) update a
    /// popup that is already open but don't open one.
    private func worthPoppingUp(_ event: PlugWatcher.Event) -> Bool {
        guard event.kind == .changed, let before = event.previous else { return true }
        let now = event.verdict
        return popup.isShowing(now.port)
            || before.settling != now.settling
            || (before.dataLink == nil) != (now.dataLink == nil)
            || before.awaitingApproval != now.awaitingApproval
            || before.display != now.display
            || before.thunderbolt != now.thunderbolt
            || now.finishedCharging(since: before)
    }

    private func updateIcon(_ verdicts: [PortVerdict]) {
        let attached = verdicts.filter(\.attached)
        let name = if attached.contains(where: \.awaitingApproval) { "lock.shield" }
            else if attached.contains(where: \.settling) { "ellipsis.circle" }
            else if attached.contains(where: { $0.dataLink != nil || $0.display || $0.thunderbolt }) { "cable.connector" }
            else if attached.contains(where: { $0.power.direction == .outOfMac }) { "battery.100.bolt" }
            else if attached.contains(where: { $0.power.direction == .intoMac }) { "bolt.fill" }
            else { "powerplug" }
        item.button?.image = symbol(name)
        item.button?.toolTip = attached.isEmpty ? "PlugSense: nothing plugged in"
            : attached.map { "\($0.port): \($0.mode)" }.joined(separator: "\n")
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "PlugSense")
            ?? NSImage(systemSymbolName: "cable.connector", accessibilityDescription: "PlugSense")
    }
}
