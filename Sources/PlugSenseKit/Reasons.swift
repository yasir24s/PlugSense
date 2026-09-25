import Foundation

extension Classifier {
    /// Which rules fired for `v`, and on what evidence: the answer to "why?".
    func reasons(for v: PortVerdict, port: PortEvidence, partners: [USBDeviceEvidence]) -> [String] {
        var why = [port.id == .unmapped ? "R0 · these USB devices can't be traced to a physical port"
                   : port.connectionActive ? "R0 · the port's CC logic sees a partner"
                   : "R0 · USB devices hang off this port"]

        let watts = Format.watts(v.power.milliwatts ?? 0)
        switch v.power.direction {
        case .intoMac:
            let offer = port.powerSources.first { $0.winning != nil }?.name ?? "power"
            let terms = v.power.contract.map { " (\(Format.volts($0.millivolts)) × \(Format.amps($0.milliamps)))" } ?? ""
            why.append("R1 · the Mac accepted the partner's \(offer) offer: \(watts)\(terms)")
        case .standby:
            why.append("R1b · a charger offers up to \(watts), but the Mac is drawing from another port")
        case .outOfMac where v.power.measured:
            // Observed: the meter holds each sample ~20 s, so one reading can be a plug-in spike.
            why.append("R2 · the Mac meters \(watts) leaving this port (one sample; the meter refreshes about every 20 s)")
        case .outOfMac:
            why.append("R2b · the Mac hasn't metered this port yet; \(watts) is the most the device is allowed "
                       + "to draw, not what it draws")
        case .neither:
            why.append("R2 · no power flow seen in either direction")
        }

        if v.dataLink != nil {
            if partners.isEmpty { why.append("R3 · a USB link is up, but nothing has enumerated on it yet") }
            for device in partners {
                let name = device.report?.modelName ?? device.name
                let what = device.vendorID == USBVendor.apple && appleRestoreProductIDs.contains(device.productID)
                    ? String(format: "Apple product ID 0x%04X is a restore mode", device.productID)
                    : device.interfaces.isEmpty ? "no interfaces"
                    : tally(device.interfaces.compactMap { describe($0, vendorID: device.vendorID) })
                        .joined(separator: ", ")
                why.append("R3 · \(name): \(what)")
            }
            if let limit = linkLimit(partners, port: port) { why.append("R3b · \(limit.long)") }
        } else {
            let links = port.transportsActive.isEmpty ? "none" : port.transportsActive.joined(separator: ", ")
            why.append("R3 · no USB data link; live transports: \(links)")
        }
        if v.display { why.append("R4 · DisplayPort is carrying a display") }
        if v.thunderbolt { why.append("R5 · a Thunderbolt/USB4 (CIO) link is up") }
        if v.awaitingApproval {
            let held = v.heldTransports.isEmpty ? "its links" : v.heldTransports.joined(separator: ", ")
            why.append("R6 · macOS is holding \(held) until you allow this accessory")
        }
        switch v.power.direction {
        case .intoMac:
            why.append(v.charge == .charging ? "R7 · the Mac's battery reports that it is charging"
                                             : "R7 · the Mac's battery isn't charging, so the charger only runs the Mac")
        case .outOfMac where v.chargeMeasured:
            let reporter = partners.first { $0.report?.charging != nil }
            let name = reporter?.report?.modelName ?? reporter?.name ?? "The device"
            let level = v.batteryPercent.map { "\($0)%" } ?? "its level"
            let reports = "R7 · \(name) reports \(level) and"
            switch (v.charge, v.chargeHold) {
            case (.charging, _):
                why.append("\(reports) charging")
            case (_, .tooWarm?):
                let held = reporter?.report?.thermalLimitSeconds.map { " (\(max(1, $0 / 60)) min so far)" } ?? ""
                why.append("\(reports) not charging: its charger is holding charge because the battery is too warm"
                           + "\(held), so what it draws only runs the device")
            case (_, .other?):
                why.append("\(reports) not charging, and heat isn't why: likely a charge limit or optimized charging "
                           + "(the device doesn't say which). What it draws runs the device")
            case (_, .checking?):
                why.append("\(reports) not charging; checking whether heat is why (its heat counter updates "
                           + "about every 20 s)")
            case (_, nil):
                why.append("\(reports) not charging: what it draws runs the device, not its battery")
            }
        case .outOfMac:
            why.append("R7 · nothing on this port reports its battery, so assessCharge judged: \(v.charge.rawValue)")
        case .standby, .neither:
            break
        }
        if v.settling {
            why.append("R8 · plugged in under \(Format.seconds(settleWindow)) ago; a data link may still come up")
        }
        return why
    }

    /// Collapses repeats, keeping first-seen order: ["a", "b", "a"] → ["a ×2", "b"].
    private func tally(_ items: [String]) -> [String] {
        var counts: [String: Int] = [:]
        items.forEach { counts[$0, default: 0] += 1 }
        var seen: Set<String> = []
        return items.compactMap { item in
            guard seen.insert(item).inserted else { return nil }
            return counts[item, default: 1] > 1 ? "\(item) ×\(counts[item, default: 1])" : item
        }
    }

    /// "Apple USB Multiplexor → phone sync (open in usbmuxd)". Interfaces with no function of their own,
    /// such as a CDC data plane, are left out; so are owners that are kernel drivers rather than processes.
    private func describe(_ i: USBInterfaceEvidence, vendorID: Int) -> String? {
        guard let function = i.function(vendorID: vendorID) else { return nil }
        let name = i.name.isEmpty ? String(format: "class 0x%02X", i.interfaceClass) : i.name
        let process = i.claimedBy.flatMap { $0.hasPrefix("pid ") ? $0.components(separatedBy: ", ").last : nil }
        return "\(name) → \(function.rawValue)" + (process.map { " (open in \($0))" } ?? "")
    }
}
