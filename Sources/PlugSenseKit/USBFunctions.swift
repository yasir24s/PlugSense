/// USB vendor IDs the protocol has opinions about.
public enum USBVendor {
    public static let apple = 0x05AC
    public static let google = 0x18D1
    public static let samsung = 0x04E8
    public static let sony = 0x054C
    public static let microsoft = 0x045E
    public static let nintendo = 0x057E
    /// USB-to-serial bridge chips: FTDI, Silicon Labs CP210x, WCH CH34x, Prolific.
    static let serialBridges: Set<Int> = [0x0403, 0x10C4, 0x1A86, 0x067B]
}

/// Apple product IDs for devices in restore modes, per libirecovery: recovery 1–4, WTF, DFU, port DFU.
let appleRestoreProductIDs: Set<Int> = [0x1280, 0x1281, 0x1282, 0x1283, 0x1222, 0x1227, 0xF014]

extension USBDeviceEvidence {
    /// What this device's data link is for, from its interface triples (class, subclass, protocol).
    public var functions: [DataFunction] {
        if vendorID == USBVendor.apple, appleRestoreProductIDs.contains(productID) { return [.restore] }
        return interfaces.compactMap { $0.function(vendorID: vendorID) }
    }
}

extension USBInterfaceEvidence {
    func function(vendorID: Int) -> DataFunction? {
        switch (interfaceClass, interfaceSubclass, interfaceProtocol) {
        case (0x01, _, _): .audio
        case (0x02, 0x02, _): .serial                                                      // CDC-ACM
        case (0x02, 0x06, _), (0x02, 0x0C, _), (0x02, 0x0D, _), (0x02, 0x0E, _): .network  // ECM, EEM, NCM, MBIM
        case (0x03, _, _): .input
        case (0x06, 0x01, 0x01): .photos                                                   // PTP
        case (0x07, _, _): .printer
        case (0x08, _, _): .storage
        case (0x09, _, _), (0x0A, _, _): nil        // hub; CDC data plane (its control interface already counted)
        case (0x0B, _, _): .smartCard
        case (0x0E, _, _), (0x10, _, _): .video
        case (0x11, _, _): .billboard
        case (0xE0, 0x01, 0x03), (0xEF, 0x04, 0x01): .network                              // RNDIS
        case (0xFE, 0x01, _): .restore                                                     // DFU firmware update
        case (0xFF, 0xFE, 0x02) where vendorID == USBVendor.apple: .phoneSync              // usbmux: Finder, Xcode
        case (0xFF, 0xFD, _) where vendorID == USBVendor.apple: .network                   // Apple private Ethernet
        case (0xFF, 0x42, 0x01), (0xFF, 0x42, 0x03): .debug                                // Android ADB, fastboot
        case (0xFF, _, _) where name.localizedCaseInsensitiveContains("MTP"): .photos
        case (0xFF, _, _) where USBVendor.serialBridges.contains(vendorID): .serial
        case (0xFF, _, _): .vendor
        default: .other
        }
    }
}
