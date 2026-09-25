import SwiftUI
import PlugSenseKit

/// The popover under the menu bar item: one card per port; click a card for the reasoning.
struct PopoverView: View {
    @ObservedObject var model: AppModel
    /// ImageRenderer can't draw AppKit-backed controls, so --render shows their labels instead.
    var rendering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "cable.connector").foregroundStyle(.secondary)
                Text("PlugSense").font(.headline)
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            VStack(spacing: 8) {
                ForEach(model.verdicts, id: \.port) { verdict in
                    PortCard(verdict: verdict, expanded: model.expanded.contains(verdict.port),
                             choice: model.choice(for: verdict),
                             onChoose: verdict.deviceKey.map { key -> (ConnectionChoice?) -> Void in
                                 { model.setChoice($0, for: key) }
                             },
                             interactive: !rendering)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard verdict.attached else { return }
                            withAnimation(.snappy) { model.toggle(verdict.port) }
                        }
                }
                if model.verdicts.isEmpty {
                    Text("This Mac exposes no USB-C port controllers to read.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            Divider()
            footer
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 380)
    }

    @ViewBuilder private var footer: some View {
        if rendering {
            Text("☑ Pop up on plug-in          Copy evidence   Quit").foregroundStyle(.secondary)
        } else {
            HStack {
                Toggle("Pop up on plug-in", isOn: $model.popUpOnPlug).toggleStyle(.checkbox)
                Spacer()
                Button("Copy evidence") { model.copyEvidence() }
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
        }
    }

    private var summary: String {
        let inUse = model.verdicts.filter(\.attached).count
        return inUse == 0 ? "nothing plugged in" : "\(inUse) of \(model.verdicts.count) ports in use"
    }
}

/// One port: what is on it, what it is doing, and (expanded) why the protocol thinks so.
struct PortCard: View {
    let verdict: PortVerdict
    var expanded = false
    /// False in the popup, where a click opens the popover instead of expanding the card.
    var expandable = true
    /// The user's answer to "Use this connection for…" for this device, if any.
    var choice: ConnectionChoice?
    /// Set in the popover, so the expanded card can change or forget that answer.
    var onChoose: ((ConnectionChoice?) -> Void)?
    /// False under --render, which can't draw AppKit-backed controls.
    var interactive = true

    private var chips: [Chip] {
        verdict.chips + (verdict.attached && choice == .dataOnly ? [Chip(label: "Data only", color: .indigo)] : [])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: verdict.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(verdict.tint)
                .frame(width: 34, height: 34)
                .background(verdict.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verdict.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verdict.port.description).font(.caption).foregroundStyle(.secondary)
                    if verdict.attached, expandable {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                if !chips.isEmpty { ChipRow(chips: chips) }
                ForEach(verdict.detailLines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if expanded {
                    if let onChoose, verdict.canAskChargeOrData || choice != nil {
                        ChoiceRow(choice: choice, interactive: interactive, set: onChoose)
                    }
                    WhyPanel(verdict: verdict)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(verdict.attached ? 0.05 : 0.025),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(verdict.attached ? 1 : 0.65)
    }
}

struct ChipRow: View {
    let chips: [Chip]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(chips, id: \.self) { chip in
                HStack(spacing: 3) {
                    if chip.busy { ProgressView().controlSize(.mini) }
                    Text(chip.label)
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .foregroundStyle(chip.color)
                .background(chip.color.opacity(0.14), in: Capsule())
            }
        }
    }
}

/// Changes or forgets the answer to "Use this connection for…". "Ask" forgets it: the next plug-in asks.
struct ChoiceRow: View {
    let choice: ConnectionChoice?
    var interactive = true
    let set: (ConnectionChoice?) -> Void

    private enum Option: Hashable { case ask, chargeAndData, dataOnly }

    private var option: Option {
        switch choice {
        case nil: .ask
        case .chargeAndData?: .chargeAndData
        case .dataOnly?: .dataOnly
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Use for").font(.caption).foregroundStyle(.secondary)
            if interactive {
                Picker("Use for", selection: Binding(get: { option }, set: { set(Self.choice(for: $0)) })) {
                    Text("Ask").tag(Option.ask)
                    Text("Charge + data").tag(Option.chargeAndData)
                    Text("Data only").tag(Option.dataOnly)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            } else {
                Text(label).font(.caption)
            }
        }
        .padding(.top, 3)
    }

    private var label: String {
        switch option {
        case .ask: "Ask on next plug-in"
        case .chargeAndData: "Charge + data"
        case .dataOnly: "Data only"
        }
    }

    private static func choice(for option: Option) -> ConnectionChoice? {
        switch option {
        case .ask: nil
        case .chargeAndData: .chargeAndData
        case .dataOnly: .dataOnly
        }
    }
}

/// The rules that fired, one per line: "R2  the Mac meters 1.4 W leaving this port".
struct WhyPanel: View {
    let verdict: PortVerdict

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why").font(.caption.weight(.semibold))
            ForEach(Array(verdict.reasons.enumerated()), id: \.offset) { _, reason in
                let (rule, text) = split(reason)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(rule)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            if verdict.awaitingApproval {
                Button("Open Privacy & Security…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.top, 3)
    }

    private func split(_ reason: String) -> (String, String) {
        guard let dot = reason.range(of: " · ") else { return ("", reason) }
        return (String(reason[..<dot.lowerBound]), String(reason[dot.upperBound...]))
    }
}
