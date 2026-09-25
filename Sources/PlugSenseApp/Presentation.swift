import SwiftUI
import PlugSenseKit

/// A small colored label: "Charging", "Data", "Display".
struct Chip: Hashable {
    var label: String
    var color: Color
    var busy = false
}

/// How a verdict looks on screen. The decisions themselves live in PlugSenseKit.
extension PortVerdict {
    /// A device's own battery says it filled up: it was charging and now reports 100%. A stop below
    /// full can be heat rather than completion, so it isn't announced as finished; the card labels it.
    func finishedCharging(since before: PortVerdict) -> Bool {
        before.charge == .charging && charge != .charging && chargeMeasured && power.direction == .outOfMac
            && (batteryPercent ?? 0) >= 100
    }

    /// Whether PlugSense can ask "charge or data?" here and keep its promise to watch: power flows
    /// to a device with a data link, and whether that device is charging is known.
    var canAskChargeOrData: Bool {
        attached && !settling && power.direction == .outOfMac && dataLink != nil && deviceKey != nil
            && (chargeMeasured || charge != .unknown)
    }

    var title: String {
        if !devices.isEmpty { return devices.joined(separator: ", ") }
        guard attached else { return "Empty" }
        switch power.direction {
        case .intoMac, .standby: return power.source ?? "Charger"
        case .outOfMac, .neither: break
        }
        if display { return "Display" }
        return settling ? "New connection" : "Unidentified device"
    }

    var symbol: String {
        guard attached else { return "circle.dashed" }
        if settling { return "ellipsis" }
        if awaitingApproval { return "lock.shield" }
        if data.contains(.restore) { return "wrench.and.screwdriver" }
        if data.contains(.phoneSync) { return "iphone" }
        if display { return "display" }
        if data.contains(.storage) { return "externaldrive" }
        if data.contains(.video) { return "web.camera" }
        if data.contains(.audio) { return "headphones" }
        if data.contains(.input) { return "keyboard" }
        if data.contains(.network) { return "network" }
        if data.contains(.printer) { return "printer" }
        if thunderbolt { return "bolt.horizontal" }
        switch power.direction {
        case .intoMac: return "bolt.fill"
        case .standby: return "powerplug"
        case .outOfMac: return dataLink == nil ? "battery.100.bolt" : "cable.connector"
        case .neither: return "cable.connector"
        }
    }

    var tint: Color {
        guard attached, !settling else { return .secondary }
        if awaitingApproval { return .orange }
        if power.direction == .intoMac || charge == .charging { return .green }
        if display { return .purple }
        if dataLink != nil { return .blue }
        return .secondary
    }

    var chips: [Chip] {
        guard attached else { return [] }
        if settling { return [Chip(label: "Connecting…", color: .secondary, busy: true)] }
        var chips: [Chip] = []
        switch power.direction {
        case .intoMac:
            chips.append(Chip(label: charge == .charging ? "Charging the Mac" : "Powering the Mac", color: .green))
        case .standby:
            chips.append(Chip(label: "Standby charger", color: .secondary))
        case .outOfMac:
            switch charge {
            case .charging:
                chips.append(Chip(label: batteryPercent.map { "Charging · \($0)%" } ?? "Charging", color: .green))
            case .poweredOnly where chargeMeasured:   // the device's own battery says it isn't taking charge
                if chargeHold == .tooWarm {
                    chips.append(Chip(label: "Charging held · too warm", color: .orange))
                } else {
                    let label = batteryPercent.map { $0 >= 100 ? "Full · not charging" : "Not charging · \($0)%" }
                    chips.append(Chip(label: label ?? "Not charging", color: .mint))
                }
            case .poweredOnly: chips.append(Chip(label: "Bus-powered", color: .secondary))
            case .idle: chips.append(Chip(label: "Idle", color: .secondary))
            case .unknown, .notApplicable: chips.append(Chip(label: "Powered", color: .secondary))
            }
        case .neither:
            break
        }
        if dataLink != nil {
            chips.append(Chip(label: "Data", color: .blue))
        } else if awaitingApproval {
            chips.append(Chip(label: "Waiting for approval", color: .orange))
        } else if power.direction == .outOfMac, !display, !thunderbolt {
            chips.append(Chip(label: "No data", color: .secondary))
        }
        if display { chips.append(Chip(label: "Display", color: .purple)) }
        if thunderbolt { chips.append(Chip(label: "Thunderbolt", color: .orange)) }
        return chips
    }

    /// What the data link is for, then the link and power figures.
    var detailLines: [String] {
        guard attached, !settling else { return [] }
        var lines: [String] = []
        if !data.isEmpty { lines.append(data.map(\.rawValue).joined(separator: " · ")) }
        let figures = [dataLink, power.summary].compactMap { $0 }
        if !figures.isEmpty { lines.append(figures.joined(separator: " · ")) }
        if let linkNote { lines.append(linkNote) }
        if awaitingApproval {
            lines.append(heldTransports.isEmpty ? "Allow the accessory to use its data link."
                         : "Holding \(heldTransports.joined(separator: ", ")) until you allow the accessory.")
        }
        return lines
    }
}
