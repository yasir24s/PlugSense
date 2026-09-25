import Foundation

/// What one port is doing, as decided by `Classifier`.
public struct PortVerdict: Codable, Sendable, Equatable {
    public var port: PortID
    public var attached: Bool
    public var power: PowerFlow
    /// Whether the battery on the receiving end of `power` is filling up.
    public var charge: ChargeAssessment
    /// True when `charge` comes from the battery's own report (the Mac's, or an iPhone's or iPad's),
    /// false when `assessCharge` inferred it from the outside.
    public var chargeMeasured: Bool
    /// The receiving device's battery level, when it reports one.
    public var batteryPercent: Int?
    /// Why a reporting device below full isn't charging: too warm, something else, or still checking.
    public var chargeHold: ChargeHold?
    /// "USB 2.0 · 480 Mb/s", or nil when there is no USB data link.
    public var dataLink: String?
    /// Why the link is slower than the device can go, when known: "Cable-limited: …".
    public var linkNote: String?
    /// What the data link is for.
    public var data: [DataFunction]
    public var display: Bool
    public var thunderbolt: Bool
    /// macOS is holding links back until the user allows this accessory.
    public var awaitingApproval: Bool
    /// The held links, when macOS says which.
    public var heldTransports: [String]
    /// Just plugged in with no link yet: one may still be coming up.
    public var settling: Bool
    public var devices: [String]
    /// A stable, non-identifying key for the main device on the port, so apps can remember choices
    /// per device: its model for iPhones and iPads ("apple:iPhone18,2"), else "usb:<vendor>:<product>".
    public var deviceKey: String?
    /// Which rules fired and on what evidence, in rule order: "R2 · the Mac meters 2.3 W …".
    public var reasons: [String]

    static func empty(_ port: PortID) -> PortVerdict {
        PortVerdict(port: port, attached: false, power: .neither, charge: .notApplicable, chargeMeasured: false,
                    batteryPercent: nil, chargeHold: nil, dataLink: nil, linkNote: nil, data: [], display: false,
                    thunderbolt: false,
                    awaitingApproval: false, heldTransports: [], settling: false, devices: [], deviceKey: nil,
                    reasons: [])
    }
}

public struct PowerFlow: Codable, Sendable, Equatable {
    public enum Direction: String, Codable, Sendable {
        case intoMac, outOfMac
        /// A charger is attached, but the Mac is drawing from another port.
        case standby
        case neither
    }

    public var direction: Direction
    /// intoMac: the negotiated contract. outOfMac: metered if `measured`, else the USB budget.
    /// standby: the best offer.
    public var milliwatts: Int?
    public var measured: Bool
    public var contract: PowerContract?
    /// The adapter or power-source name, for power into the Mac.
    public var source: String?

    public static let neither = PowerFlow(direction: .neither, milliwatts: nil, measured: false, contract: nil, source: nil)

    /// "94.0 W in (20 V × 4.7 A)", "2.3 W out", "up to 12.0 W allowed, not metered yet", "offering 30.0 W, unused".
    public var summary: String? {
        guard let mW = milliwatts else { return nil }
        switch direction {
        case .intoMac:
            let terms = contract.map { " (\(Format.volts($0.millivolts)) × \(Format.amps($0.milliamps)))" } ?? ""
            return "\(Format.watts(mW)) in\(terms)"
        case .standby: return "offering \(Format.watts(mW)), unused"
        // A budget is the most the device may draw, not what it draws: never print it as a flow.
        case .outOfMac: return measured ? "\(Format.watts(mW)) out" : "up to \(Format.watts(mW)) allowed, not metered yet"
        case .neither: return nil
        }
    }
}

public enum ChargeAssessment: String, Codable, Sendable {
    /// The receiving battery is filling up.
    case charging
    /// The receiving end runs on this power without filling a battery (bus-powered drive, full Mac).
    case poweredOnly = "powered only"
    /// Powered, but drawing next to nothing.
    case idle
    /// Power flows out of the Mac, but the evidence can't say what it is doing.
    case unknown
    /// No power flows toward a battery we can reason about.
    case notApplicable = "n/a"
}

/// What a USB data link is for, judged from the interfaces the device offers.
public enum DataFunction: String, Codable, Sendable, CaseIterable, Comparable {
    case phoneSync = "phone sync"
    case restore = "restore/DFU"
    case photos = "photo import"
    case storage
    case network
    case debug = "debug bridge"
    case input
    case audio
    case video
    case serial
    case printer
    case smartCard = "smart card"
    case billboard = "billboard (alt mode refused)"
    case vendor = "vendor-specific"
    case other

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

extension PortVerdict {
    /// The fields events fire on. Leaves out meter readings, which drift while nothing changes.
    public struct Decision: Equatable, Sendable {
        var attached: Bool
        var power: PowerFlow.Direction
        var charge: ChargeAssessment
        var chargeHold: ChargeHold?
        var dataLink: Bool
        var data: [DataFunction]
        var display: Bool
        var thunderbolt: Bool
        var awaitingApproval: Bool
        var settling: Bool
    }

    public var decision: Decision {
        Decision(attached: attached, power: power.direction, charge: charge, chargeHold: chargeHold,
                 dataLink: dataLink != nil, data: data,
                 display: display, thunderbolt: thunderbolt, awaitingApproval: awaitingApproval, settling: settling)
    }

    /// The protocol's answer in a few words: "charging + data", "charge only", "powering the Mac + display".
    public var mode: String {
        guard attached else { return "empty" }
        if settling { return "connecting…" }
        let links = [dataLink != nil ? "data" : awaitingApproval ? "data held for approval" : nil,
                     display ? "display" : nil,
                     thunderbolt ? "Thunderbolt" : nil].compactMap { $0 }
        if links.isEmpty, power.direction == .outOfMac {
            return charge == .charging ? "charge only" : "power only"
        }
        let parts = [powerLabel].compactMap { $0 } + links
        return parts.isEmpty ? "attached" : parts.joined(separator: " + ")
    }

    private var powerLabel: String? {
        switch power.direction {
        case .intoMac: charge == .charging ? "charging the Mac" : "powering the Mac"
        case .standby: "charger (standby)"
        case .outOfMac:
            switch charge {
            case .charging: "charging"
            case .poweredOnly where chargeMeasured:
                chargeHold == .tooWarm ? "charging held (too warm)"
                    : batteryPercent.map { $0 >= 100 } ?? false ? "full" : "not charging"
            case .poweredOnly: "bus-powered"
            case .idle: "idle"
            case .unknown, .notApplicable: "powered"
            }
        case .neither: nil
        }
    }

    /// The evidence behind `mode`, for people.
    public var details: String {
        var parts: [String] = []
        if !devices.isEmpty {
            let uses = data.isEmpty ? "" : " — " + data.map(\.rawValue).joined(separator: ", ")
            parts.append(devices.joined(separator: ", ") + uses)
        }
        if let dataLink { parts.append(dataLink) }
        if awaitingApproval {
            parts.append(heldTransports.isEmpty ? "waiting for you to allow it"
                                                : "holding \(heldTransports.joined(separator: ", ")) until you allow it")
        }
        if let summary = power.summary {
            switch power.direction {
            case .intoMac: parts.append("\(power.source ?? "charger"): \(summary)")
            case .standby: parts.append("\(power.source ?? "charger") \(summary)")
            case .outOfMac, .neither: parts.append(summary)
            }
        }
        return parts.joined(separator: " · ")
    }
}

enum Format {
    static func watts(_ mW: Int) -> String { String(format: "%.1f W", Double(mW) / 1000) }
    static func volts(_ mV: Int) -> String { String(format: "%g V", Double(mV) / 1000) }
    static func amps(_ mA: Int) -> String { String(format: "%g A", Double(mA) / 1000) }
    static func seconds(_ s: TimeInterval) -> String { String(format: "%g s", s) }
    static func rate(_ bps: Int) -> String {
        bps >= 1_000_000_000 ? String(format: "%g Gb/s", Double(bps) / 1e9) : String(format: "%g Mb/s", Double(bps) / 1e6)
    }
}
