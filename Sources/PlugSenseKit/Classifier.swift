import Foundation

/// The PlugSense protocol: one `Snapshot` in, one verdict per port out. Pure and deterministic.
/// Rule numbers match PROTOCOL.md.
public struct Classifier: Sendable {
    /// R8: how long a fresh connection may show power without data before we conclude there is no
    /// data link, rather than one that is still enumerating.
    public var settleWindow: TimeInterval

    public init(settleWindow: TimeInterval = 3) {
        self.settleWindow = settleWindow
    }

    /// - Parameter plugTimes: when each port's current connection began, if it began while watching.
    public func classify(_ snapshot: Snapshot, plugTimes: [PortID: Date] = [:], now: Date = Date()) -> [PortVerdict] {
        var devicesByPort = Dictionary(grouping: snapshot.usbDevices) { $0.port ?? .unmapped }
        // R3a: devices that can't be traced to a root port but came through a USB4/Thunderbolt tunnel
        // belong to the port carrying the tunnel, when exactly one port does.
        let tunnelPorts = snapshot.ports.filter { $0.connectionActive && $0.transportsActive.contains("CIO") }
        if tunnelPorts.count == 1, let stray = devicesByPort.removeValue(forKey: .unmapped) {
            devicesByPort[tunnelPorts[0].id, default: []] += stray
        }
        var ports = snapshot.ports
        if devicesByPort[.unmapped] != nil {
            ports.append(PortEvidence(id: .unmapped, connectionActive: true, connectionUUID: nil, transportsSupported: [],
                                      transportsActive: [], transportsUnauthorized: [], authorizationPending: false,
                                      displayHotPlug: false, powerSources: []))
        }
        return ports.map { port in
            let justPlugged = plugTimes[port.id].map { now.timeIntervalSince($0) < settleWindow } ?? false
            return verdict(for: port, devices: devicesByPort[port.id] ?? [], in: snapshot, justPlugged: justPlugged)
        }.sorted { $0.port < $1.port }
    }

    func verdict(for port: PortEvidence, devices: [USBDeviceEvidence], in snapshot: Snapshot,
                 justPlugged: Bool) -> PortVerdict {
        // R0 — attachment: the CC logic sees a partner, or USB devices hang off the port.
        guard port.connectionActive || !devices.isEmpty else { return .empty(port.id) }
        let active = Set(port.transportsActive)

        // R3 — data: a USB link is live; what it is for comes from the interface table.
        let usbLive = !devices.isEmpty || active.contains("USB2") || active.contains("USB3")
        let partners = devices.filter { $0.deviceClass != 0x09 }   // hubs are plumbing, not partners
        let functions = Array(Set(partners.flatMap(\.functions))).sorted()
        // R4, R5 — a display and a Thunderbolt/USB4 tunnel are links of their own.
        let display = active.contains("DisplayPort") || port.displayHotPlug
        let thunderbolt = active.contains("CIO")
        // R6 — accessory security can hold links back until the user allows the accessory.
        let awaitingApproval = port.authorizationPending || !port.transportsUnauthorized.isEmpty
        // R1, R2 — which way power flows.
        let power = powerFlow(port: port, devices: devices, in: snapshot)
        // R7 — is the battery on the receiving end filling up? Measured wherever that battery reports
        // itself (the Mac's, or a trusting iPhone's or iPad's); otherwise inferred by assessCharge.
        let reporting = partners.compactMap(\.report).filter { $0.charging != nil }
        let assessed: (ChargeAssessment, Bool) = switch power.direction {
        case .intoMac:
            (snapshot.macBatteryCharging == true ? .charging : .poweredOnly, true)
        case .outOfMac where !reporting.isEmpty:
            (reporting.contains { $0.charging == true } ? .charging : .poweredOnly, true)
        case .outOfMac:
            (assessCharge(ChargeEvidence(devices: partners, functions: Set(functions),
                                         drawMilliwatts: power.measured ? power.milliwatts : nil)), false)
        case .standby, .neither:
            (.notApplicable, false)
        }
        let (charge, chargeMeasured) = assessed
        // R7b — below full and not charging, the device's charger may say why (settled across two looks).
        let chargeHold = chargeMeasured && charge != .charging && power.direction == .outOfMac
            ? reporting.lazy.compactMap(\.hold).first : nil
        // R8 — a fresh connection with no link yet may still be enumerating.
        let settling = justPlugged && !usbLive && !display && !thunderbolt && !awaitingApproval
        let primary = partners.first { $0.report != nil } ?? partners.first

        var verdict = PortVerdict(port: port.id, attached: true, power: power, charge: charge,
                                  chargeMeasured: chargeMeasured,
                                  batteryPercent: power.direction == .outOfMac ? reporting.first?.batteryPercent : nil,
                                  chargeHold: chargeHold,
                                  dataLink: usbLive ? linkDescription(devices, active) : nil,
                                  linkNote: usbLive ? linkLimit(partners, port: port)?.short : nil, data: functions,
                                  display: display, thunderbolt: thunderbolt, awaitingApproval: awaitingApproval,
                                  heldTransports: port.transportsUnauthorized, settling: settling,
                                  devices: partners.map { $0.report?.modelName ?? $0.name },
                                  deviceKey: primary.map { device in
                                      device.report.map { "apple:\($0.productType)" }
                                          ?? String(format: "usb:%04x:%04x", device.vendorID, device.productID)
                                  },
                                  reasons: [])
        verdict.reasons = reasons(for: verdict, port: port, partners: partners)
        return verdict
    }

    /// R3b: why a USB link runs slower than the device on it can go, when we know what the device can do.
    func linkLimit(_ partners: [USBDeviceEvidence], port: PortEvidence) -> (short: String, long: String)? {
        for device in partners {
            guard let report = device.report, let fastest = report.fastestUSB,
                  let speed = device.linkSpeed, speed < 5_000_000_000 else { continue }
            let name = report.modelName ?? report.productType
            guard fastest >= 5_000_000_000 else {
                return ("\(name) tops out at USB 2.0",
                        "\(name) only supports USB 2.0 (480 Mb/s), so no cable or port will make it faster")
            }
            let rate = Format.rate(fastest)
            if port.transportsSupported.isEmpty {   // a port we can't see into
                return ("\(name) can do \(rate) over a faster link",
                        "\(name) supports \(rate), but linked at \(Format.rate(speed)): the cable or the port is USB 2.0")
            }
            return port.transportsSupported.contains("USB3")
                ? ("Cable-limited: \(name) can do \(rate)",
                   "\(name) and this port both support \(rate), but only the cable's USB 2 wires linked: "
                       + "the cable is almost certainly USB 2.0-only")
                : ("Port-limited: \(name) can do \(rate)", "\(name) supports \(rate), but this port only offers USB 2.0")
        }
        return nil
    }

    func powerFlow(port: PortEvidence, devices: [USBDeviceEvidence], in snapshot: Snapshot) -> PowerFlow {
        // R1 — the Mac accepted one of the partner's offers: power flows into the Mac.
        if let source = port.powerSources.first(where: { $0.winning != nil }), let contract = source.winning {
            return PowerFlow(direction: .intoMac, milliwatts: contract.milliwatts, measured: false,
                             contract: contract, source: snapshot.adapter?.name ?? source.name)
        }
        // R1b — offers the Mac isn't taking: a charger on standby while another port powers the Mac.
        if let best = port.powerSources.max(by: { $0.maxMilliwatts < $1.maxMilliwatts }), best.maxMilliwatts > 0 {
            return PowerFlow(direction: .standby, milliwatts: best.maxMilliwatts, measured: false,
                             contract: nil, source: best.name)
        }
        // R2 — the Mac meters what it delivers on each USB-C port (laptops only).
        if port.id.type == "USB-C", let out = snapshot.powerOut.first(where: { $0.portNumber == port.id.number }) {
            return PowerFlow(direction: .outOfMac, milliwatts: out.milliwatts, measured: true, contract: nil, source: nil)
        }
        // R2b — no meter reading: fall back to what the USB stack budgeted (mA at 5 V).
        let milliamps = devices.compactMap(\.powerAllocationMilliamps).reduce(0, +)
        return milliamps > 0
            ? PowerFlow(direction: .outOfMac, milliwatts: milliamps * 5, measured: false, contract: nil, source: nil)
            : .neither
    }

    func linkDescription(_ devices: [USBDeviceEvidence], _ active: Set<String>) -> String {
        let fastest = devices.compactMap(\.linkSpeed).max() ?? 0
        guard fastest > 0 else { return active.contains("USB3") ? "USB 3" : "USB 2.0" }
        let generation = fastest >= 5_000_000_000 ? "USB 3" : fastest > 12_000_000 ? "USB 2.0" : "USB 1.1"
        return "\(generation) · \(Format.rate(fastest))"
    }
}
