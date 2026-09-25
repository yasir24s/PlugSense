import Foundation
import IOKit
import IOKit.ps

/// Reads a `Snapshot` from the I/O Registry and IOPowerSources. Needs no privileges or TCC grants.
public enum Probe {
    public static func snapshot() -> Snapshot {
        let battery = batteryReadings()
        return Snapshot(takenAt: Date(), ports: ports(), usbDevices: usbDevices(), powerOut: battery.powerOut,
                        macBatteryCharging: battery.charging, adapter: adapter())
    }

    /// A snapshot taken after giving connected iPhones and iPads up to `timeout` to report themselves.
    /// For one-shot callers on the main thread; `PlugWatcher` keeps reports current instead.
    public static func snapshot(waitingForAppleDevices timeout: TimeInterval) -> Snapshot {
        AppleDevices.shared.start()
        AppleDevices.shared.waitForReports(serials: appleMuxSerials(), timeout: timeout)
        return snapshot()
    }

    /// USB serial numbers of Apple devices offering usbmux: the ones lockdown can answer for.
    static func appleMuxSerials() -> [String] {
        Registry.each("IOUSBHostDevice") { entry, p -> String? in
            guard p["idVendor"] as? Int == USBVendor.apple, let serial = serialNumber(p) else { return nil }
            let mux = Registry.eachChild(of: entry, conformingTo: "IOUSBHostInterface") { _, i -> Bool? in
                i["bInterfaceClass"] as? Int == 0xFF && i["bInterfaceSubClass"] as? Int == 0xFE ? true : nil
            }
            return mux.isEmpty ? nil : serial
        }
    }

    static func serialNumber(_ p: [String: Any]) -> String? {
        p["kUSBSerialNumberString"] as? String ?? p["USB Serial Number"] as? String
    }

    /// Port controllers: every IOPort that names its type and number (AppleTCControllerType10 on M2).
    static func ports() -> [PortEvidence] {
        let offers = Dictionary(grouping: powerSources()) { $0.port }
        return Registry.each("IOPort") { _, p in
            guard let type = p["PortTypeDescription"] as? String, let number = p["PortNumber"] as? Int else { return nil }
            let id = PortID(type, number)
            return PortEvidence(
                id: id,
                connectionActive: p["ConnectionActive"] as? Bool ?? false,
                connectionUUID: p["ConnectionUUID"] as? String,
                transportsSupported: p["TransportsSupported"] as? [String] ?? [],
                transportsActive: p["TransportsActive"] as? [String] ?? [],
                transportsUnauthorized: p["TransportsUnauthorized"] as? [String] ?? [],
                authorizationPending: p["AuthorizationPending"] as? Bool == true
                    || p["UserAuthorizationPending"] as? Bool == true,
                displayHotPlug: p["HPDAsserted"] as? Bool ?? false,
                powerSources: offers[id]?.map { $0.source } ?? [])
        }
    }

    /// Offers to power the Mac, with the port each arrived on.
    static func powerSources() -> [(port: PortID, source: PowerSourceEvidence)] {
        Registry.each("IOPortFeaturePowerSource") { _, p in
            guard let type = p["ParentPortTypeDescription"] as? String,
                  let number = p["ParentPortNumber"] as? Int else { return nil }
            let offers = (p["PowerSourceOptions"] as? [[String: Any]] ?? []).map(contract)
            return (PortID(type, number), PowerSourceEvidence(
                name: p["PowerSourceName"] as? String ?? "unknown",
                maxMilliwatts: offers.map(\.milliwatts).max() ?? 0,
                winning: (p["WinningPowerSourceOption"] as? [String: Any]).map(contract)))
        }
    }

    static func contract(_ option: [String: Any]) -> PowerContract {
        PowerContract(millivolts: option["Voltage (mV)"] as? Int ?? 0,
                      milliamps: option["Max Current (mA)"] as? Int ?? 0,
                      milliwatts: option["Max Power (mW)"] as? Int ?? 0)
    }

    static func usbDevices() -> [USBDeviceEvidence] {
        Registry.each("IOUSBHostDevice") { entry, p in
            guard let vendorID = p["idVendor"] as? Int, let productID = p["idProduct"] as? Int,
                  p["USBPortType"] as? Int != 2   // kIOUSBHostPortTypeInternal: built into the Mac
            else { return nil }
            return USBDeviceEvidence(
                name: p["kUSBProductString"] as? String ?? p["USB Product Name"] as? String ?? Registry.name(of: entry),
                vendorID: vendorID,
                productID: productID,
                deviceClass: p["bDeviceClass"] as? Int ?? 0,
                linkSpeed: p["UsbLinkSpeed"] as? Int,
                port: physicalPort(of: entry),
                tunneled: p["UsbTunnel"] as? Bool ?? false,
                powerAllocationMilliamps: p["UsbPowerSinkAllocation"] as? Int,
                interfaces: Registry.eachChild(of: entry, conformingTo: "IOUSBHostInterface") { child, i in
                    USBInterfaceEvidence(
                        name: Registry.name(of: child).components(separatedBy: "@")[0],
                        interfaceClass: i["bInterfaceClass"] as? Int ?? 0,
                        interfaceSubclass: i["bInterfaceSubClass"] as? Int ?? 0,
                        interfaceProtocol: i["bInterfaceProtocol"] as? Int ?? 0,
                        claimedBy: i["UsbExclusiveOwner"] as? String)
                },
                // The serial number is used for this lookup only; it never enters the evidence.
                report: vendorID == USBVendor.apple
                    ? serialNumber(p).flatMap(AppleDevices.shared.report(forUSBSerial:)) : nil)
        }
    }

    /// On Apple Silicon each root port carries "UsbIOPort", the registry path of the USB-C port it is
    /// wired to. Searching up from a device finds it through any number of hubs.
    static func physicalPort(of device: io_registry_entry_t) -> PortID? {
        guard let path = Registry.inheritedProperty(of: device, "UsbIOPort") as? String else { return nil }
        let port = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard port != 0 else { return nil }
        defer { IOObjectRelease(port) }
        guard let type = Registry.property(of: port, "PortTypeDescription") as? String,
              let number = Registry.property(of: port, "PortNumber") as? Int else { return nil }
        return PortID(type, number)
    }

    /// PowerOutDetails and IsCharging from the battery controller. Macs without a battery have neither.
    static func batteryReadings() -> (powerOut: [PowerOutEvidence], charging: Bool?) {
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return ([], nil) }
        defer { IOObjectRelease(battery) }
        let details = Registry.property(of: battery, "PowerOutDetails") as? [[String: Any]] ?? []
        let powerOut = details.compactMap { d -> PowerOutEvidence? in
            guard let port = d["PortIndex"] as? Int else { return nil }
            return PowerOutEvidence(portNumber: port, milliwatts: d["Watts"] as? Int ?? 0,
                                    milliamps: d["Current"] as? Int ?? 0,
                                    busMillivolts: d["AdapterVoltage"] as? Int ?? 0)
        }
        return (powerOut, Registry.property(of: battery, "IsCharging") as? Bool)
    }

    static func adapter() -> AdapterEvidence? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return AdapterEvidence(name: details["Name"] as? String, watts: details[kIOPSPowerAdapterWattsKey] as? Int)
    }
}
