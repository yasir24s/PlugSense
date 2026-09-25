import Foundation

/// Everything PlugSense observed at one instant. Plain data: the classifier never touches IOKit,
/// so a live snapshot, a recorded one and a hand-built test fixture all get the same verdict.
public struct Snapshot: Codable, Sendable, Equatable {
    public var takenAt = Date()
    public var ports: [PortEvidence] = []
    public var usbDevices: [USBDeviceEvidence] = []
    /// Power the Mac is delivering on each USB-C port, as metered by the battery controller. Laptops only.
    public var powerOut: [PowerOutEvidence] = []
    /// Whether the Mac's own battery is charging. nil on Macs without one.
    public var macBatteryCharging: Bool?
    /// The adapter currently powering the Mac.
    public var adapter: AdapterEvidence?
}

/// A physical port, named the way macOS names it: ("USB-C", 2) is "Port-USB-C@2".
public struct PortID: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var type: String
    public var number: Int

    public init(_ type: String, _ number: Int) {
        self.type = type
        self.number = number
    }

    /// Where USB devices go when they can't be traced to a physical port.
    public static let unmapped = PortID("USB", 0)

    public var description: String { self == .unmapped ? "USB (other)" : "\(type) \(number)" }

    public static func < (a: PortID, b: PortID) -> Bool {
        if a == .unmapped || b == .unmapped { return b == .unmapped && a != .unmapped }
        return (a.type, a.number) < (b.type, b.number)
    }
}

/// One port controller: an `IOPort` in the registry, such as "Port-USB-C@2".
public struct PortEvidence: Codable, Sendable, Equatable {
    public var id: PortID
    /// ConnectionActive: the port's CC logic sees a partner, even over a charge-only cable.
    public var connectionActive: Bool
    /// ConnectionUUID: a fresh value for every new connection.
    public var connectionUUID: String?
    /// TransportsSupported: every link this port can carry.
    public var transportsSupported: [String]
    /// TransportsActive: the live links, from "CC", "USB2", "USB3", "CIO" and "DisplayPort".
    public var transportsActive: [String]
    /// TransportsUnauthorized: links macOS is holding until the user allows the accessory.
    public var transportsUnauthorized: [String]
    /// AuthorizationPending or UserAuthorizationPending.
    public var authorizationPending: Bool
    /// HPDAsserted: a DisplayPort sink raised hot-plug detect.
    public var displayHotPlug: Bool
    /// Offers the partner makes to power the Mac (IOPortFeaturePowerSource under "Power In").
    public var powerSources: [PowerSourceEvidence]
}

/// One way the partner offers to power the Mac: "USB-PD", "TypeC" current, "Brick ID".
public struct PowerSourceEvidence: Codable, Sendable, Equatable {
    public var name: String
    /// The largest of its offers.
    public var maxMilliwatts: Int
    /// WinningPowerSourceOption: present only on the offer the Mac is actually using.
    public var winning: PowerContract?
}

public struct PowerContract: Codable, Sendable, Equatable {
    public var millivolts: Int
    public var milliamps: Int
    public var milliwatts: Int
}

/// One entry of AppleSmartBattery's PowerOutDetails. Its "Watts" key is really milliwatts
/// (5231 mV × 439 mA ≈ 2301), and the meter refreshes only every several seconds.
public struct PowerOutEvidence: Codable, Sendable, Equatable {
    /// PortIndex: the USB-C port number.
    public var portNumber: Int
    public var milliwatts: Int
    public var milliamps: Int
    /// AdapterVoltage: VBUS as measured.
    public var busMillivolts: Int
}

public struct USBDeviceEvidence: Codable, Sendable, Equatable {
    public var name: String
    public var vendorID: Int
    public var productID: Int
    public var deviceClass: Int
    /// UsbLinkSpeed, in bits per second.
    public var linkSpeed: Int?
    /// The physical port, traced through the root port's UsbIOPort; nil when untraceable.
    public var port: PortID?
    /// UsbTunnel: arrived through a USB4/Thunderbolt tunnel, e.g. behind a dock.
    public var tunneled: Bool
    /// UsbPowerSinkAllocation: mA at 5 V the USB stack expects the device to draw.
    public var powerAllocationMilliamps: Int?
    public var interfaces: [USBInterfaceEvidence]
    /// What an iPhone or iPad reports about itself (model, battery), matched by USB serial number.
    public var report: AppleDeviceReport?
}

public struct USBInterfaceEvidence: Codable, Sendable, Equatable {
    public var name: String
    public var interfaceClass: Int
    public var interfaceSubclass: Int
    public var interfaceProtocol: Int
    /// UsbExclusiveOwner: who has the interface open, e.g. "pid 395, usbmuxd".
    public var claimedBy: String?
}

public struct AdapterEvidence: Codable, Sendable, Equatable {
    public var name: String?
    public var watts: Int?
}
