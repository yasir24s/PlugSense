/// Everything known about a port where power is flowing out of the Mac.
public struct ChargeEvidence: Sendable {
    /// USB devices enumerated on the port, hubs excluded. Empty means no data link at all:
    /// a charge-only cable, a device offering no USB function, or data held for approval.
    public var devices: [USBDeviceEvidence]
    /// What those devices' data links are for (.phoneSync, .storage, .input, …).
    public var functions: Set<DataFunction>
    /// Power the Mac metered going out of this port, in mW. nil when the Mac can't meter it:
    /// desktop Macs, or the seconds after plugging in before the meter's next refresh.
    public var drawMilliwatts: Int?

    /// True if any device on the port was made by `vendorID` (see `USBVendor`).
    public func has(vendor vendorID: Int) -> Bool { devices.contains { $0.vendorID == vendorID } }
}

/// R7, outbound: power is leaving the Mac through this port. Is it filling a battery (.charging),
/// running a device that has none (.poweredOnly), barely flowing (.idle), or can't we tell (.unknown)?
///
/// Measured on this Mac: an iPhone near full charge drew 1.9–2.3 W. A USB-C port offers at most
/// 15 W (5 V × 3 A); a bus-powered SSD can pull 4.5 W with no battery anywhere.
///
/// Not decided yet: this returns `.unknown`, so a device that doesn't report its own battery shows
/// "Powered". iPhones and iPads that trust the Mac report themselves and never reach this function.
/// See PROTOCOL.md, R7, for what a good heuristic has to weigh.
func assessCharge(_ e: ChargeEvidence) -> ChargeAssessment {
    .unknown
}
