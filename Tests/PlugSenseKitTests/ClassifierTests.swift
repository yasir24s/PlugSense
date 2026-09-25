import Foundation
import Testing
@testable import PlugSenseKit

// Fixtures mirror what a Mac14,7 on macOS 27.2 reported, serial numbers left out.

private let usbC1 = PortID("USB-C", 1)
private let usbC2 = PortID("USB-C", 2)

private func port(_ id: PortID, attached: Bool = true, active: [String] = ["CC"], held: [String] = [],
                  hotPlug: Bool = false, offers: [PowerSourceEvidence] = []) -> PortEvidence {
    PortEvidence(id: id, connectionActive: attached, connectionUUID: attached ? UUID().uuidString : nil,
                 transportsSupported: ["CC", "USB2", "USB3", "CIO", "DisplayPort"],
                 transportsActive: attached ? active : [], transportsUnauthorized: held, authorizationPending: false,
                 displayHotPlug: hotPlug, powerSources: offers)
}

private func interface(_ c: Int, _ s: Int, _ p: Int, _ name: String = "") -> USBInterfaceEvidence {
    USBInterfaceEvidence(name: name, interfaceClass: c, interfaceSubclass: s, interfaceProtocol: p, claimedBy: nil)
}

private func device(_ name: String, vendor: Int, product: Int, on port: PortID?, speed: Int = 480_000_000,
                    tunneled: Bool = false, milliamps: Int? = 500, report: AppleDeviceReport? = nil,
                    _ interfaces: [USBInterfaceEvidence]) -> USBDeviceEvidence {
    USBDeviceEvidence(name: name, vendorID: vendor, productID: product, deviceClass: 0, linkSpeed: speed, port: port,
                      tunneled: tunneled, powerAllocationMilliamps: milliamps, interfaces: interfaces, report: report)
}

/// The iPhone as it reported itself on this Mac: an iPhone 17 Pro Max, full, not charging.
private func reportingPhone(_ productType: String = "iPhone18,2", percent: Int? = 100,
                            charging: Bool? = false) -> USBDeviceEvidence {
    var phone = iPhone
    phone.report = AppleDeviceReport(productType: productType, batteryPercent: percent, charging: charging,
                                     fullyCharged: percent == 100)
    return phone
}

private let iPhone = device("iPhone", vendor: USBVendor.apple, product: 0x12A8, on: usbC2, milliamps: 2400, [
    interface(0x06, 0x01, 0x01, "PTP"), interface(0xFF, 0xFE, 0x02, "Apple USB Multiplexor"),
    interface(0xFF, 0xFD, 0x01, "AppleUSBEthernet"), interface(0x02, 0x0D, 0x00, "NCM Control"),
    interface(0x0A, 0x00, 0x01, "NCM Data"),
])
private let appleCharger = PowerSourceEvidence(
    name: "USB-PD", maxMilliwatts: 94_000,
    winning: PowerContract(millivolts: 20_000, milliamps: 4_700, milliwatts: 94_000))
private let meterOnPort2 = PowerOutEvidence(portNumber: 2, milliwatts: 2_301, milliamps: 439, busMillivolts: 5_231)

private func classify(_ snapshot: Snapshot, pluggedSecondsAgo: TimeInterval? = nil) -> [PortVerdict] {
    let plugTimes = pluggedSecondsAgo.map { [usbC2: snapshot.takenAt.addingTimeInterval(-$0)] } ?? [:]
    return Classifier().classify(snapshot, plugTimes: plugTimes, now: snapshot.takenAt)
}

@Test func chargerPowersTheMacAndCarriesNoData() {
    let v = classify(Snapshot(ports: [port(usbC1, offers: [appleCharger])], macBatteryCharging: true,
                              adapter: AdapterEvidence(name: "96W USB-C Power Adapter", watts: 94)))[0]
    #expect(v.power.direction == .intoMac)
    #expect(v.power.milliwatts == 94_000)
    #expect(v.power.source == "96W USB-C Power Adapter")
    #expect(v.dataLink == nil)
    #expect(v.mode == "charging the Mac")
    #expect(v.reasons.contains { $0.hasPrefix("R1 ") })
}

@Test func fullMacIsPoweredNotCharged() {
    let v = classify(Snapshot(ports: [port(usbC1, offers: [appleCharger])], macBatteryCharging: false))[0]
    #expect(v.charge == .poweredOnly)
    #expect(v.mode == "powering the Mac")
}

@Test func iPhoneTakesPowerAndCarriesData() {
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [iPhone],
                              powerOut: [meterOnPort2]))[0]
    #expect(v.power.direction == .outOfMac)
    #expect(v.power.measured && v.power.milliwatts == 2_301)
    #expect(v.data == [.phoneSync, .photos, .network])
    #expect(v.dataLink == "USB 2.0 · 480 Mb/s")
    #expect(v.devices == ["iPhone"])
}

@Test func withoutAMeterThePowerBudgetStandsIn() {
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [iPhone]))[0]
    #expect(v.power.direction == .outOfMac)
    #expect(!v.power.measured && v.power.milliwatts == 12_000)   // 2400 mA × 5 V
    #expect(v.power.summary == "up to 12.0 W allowed, not metered yet")   // an allowance, never a flow
}

@Test func aFullPhoneSaysItIsNotCharging() {
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [reportingPhone()],
                              powerOut: [meterOnPort2]))[0]
    #expect(v.charge == .poweredOnly && v.chargeMeasured)
    #expect(v.batteryPercent == 100)
    #expect(v.reasons.contains { $0.hasPrefix("R7 ") && $0.contains("not charging") })
}

@Test func aChargingPhoneSaysSo() {
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])],
                              usbDevices: [reportingPhone(percent: 63, charging: true)], powerOut: [meterOnPort2]))[0]
    #expect(v.charge == .charging && v.chargeMeasured && v.batteryPercent == 63)
}

@Test func aWarmPhoneSaysChargingIsHeld() {
    var phone = reportingPhone(percent: 86, charging: false)
    phone.report?.hold = .tooWarm
    phone.report?.thermalLimitSeconds = 599
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [phone],
                              powerOut: [meterOnPort2]))[0]
    #expect(v.chargeHold == .tooWarm && v.charge == .poweredOnly)
    #expect(v.mode == "charging held (too warm) + data")
    #expect(v.reasons.contains { $0.hasPrefix("R7 ") && $0.contains("too warm (9 min so far)") })
}

@Test func heatIsSettledOnlyAcrossACounterUpdate() {
    let start = Date()
    let first = ChargeHold.settle(counter: 599, at: start, last: nil)
    #expect(first.hold == .checking)
    #expect(ChargeHold.settle(counter: 599, at: start + 5, last: first) == first)   // too soon to have ticked
    #expect(ChargeHold.settle(counter: 619, at: start + 22, last: first).hold == .tooWarm)
    #expect(ChargeHold.settle(counter: 599, at: start + 22, last: first).hold == .other)
}

@Test func anUntrustingPhoneFallsBackToInference() {
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])],
                              usbDevices: [reportingPhone(percent: nil, charging: nil)], powerOut: [meterOnPort2]))[0]
    #expect(!v.chargeMeasured && v.batteryPercent == nil)
}

@Test func aUSB3PhoneOnAUSB2LinkBlamesTheCable() {
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [reportingPhone()]))[0]
    #expect(v.linkNote?.hasPrefix("Cable-limited") == true)
    #expect(v.reasons.contains { $0.hasPrefix("R3b ") && $0.contains("USB 2.0-only") })
}

@Test func deviceKeysNameTheModelNotTheDevice() {
    let reported = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [reportingPhone()]))[0]
    #expect(reported.deviceKey == "apple:iPhone18,2")
    let unreported = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [iPhone]))[0]
    #expect(unreported.deviceKey == "usb:05ac:12a8")
    #expect(classify(Snapshot(ports: [port(usbC1, offers: [appleCharger])]))[0].deviceKey == nil)
}

@Test func aUSB2OnlyPhoneIsNotBlamedOnTheCable() {
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [reportingPhone("iPhone18,3")]))[0]
    #expect(v.linkNote?.hasSuffix("tops out at USB 2.0") == true)
}

@Test func powerWithoutDataSettlesIntoPowerOnly() {
    let snapshot = Snapshot(ports: [port(usbC2)], powerOut: [meterOnPort2])
    let fresh = classify(snapshot, pluggedSecondsAgo: 1)[0]
    #expect(fresh.settling && fresh.mode == "connecting…")
    let settled = classify(snapshot, pluggedSecondsAgo: 5)[0]
    #expect(!settled.settling)
    #expect(settled.dataLink == nil && settled.power.direction == .outOfMac)
    #expect(["power only", "charge only"].contains(settled.mode))
}

@Test func heldDataIsNotMistakenForChargeOnly() {
    let v = classify(Snapshot(ports: [port(usbC2, held: ["USB2"])], powerOut: [meterOnPort2]), pluggedSecondsAgo: 1)[0]
    #expect(v.awaitingApproval && v.heldTransports == ["USB2"])
    #expect(!v.settling)
    #expect(v.mode.hasSuffix("data held for approval"))
}

@Test func iPhoneInDFUIsRestoreMode() {
    let dfu = device("Apple Mobile Device (DFU Mode)", vendor: USBVendor.apple, product: 0x1227, on: usbC2,
                     speed: 12_000_000, [interface(0xFE, 0x01, 0x00)])
    let v = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [dfu]))[0]
    #expect(v.data == [.restore])
    #expect(v.dataLink == "USB 1.1 · 12 Mb/s")
}

@Test func monitorWithPowerDeliveryIsDisplayPlusPower() {
    let offer = PowerSourceEvidence(name: "USB-PD", maxMilliwatts: 60_000,
                                    winning: PowerContract(millivolts: 20_000, milliamps: 3_000, milliwatts: 60_000))
    let v = classify(Snapshot(ports: [port(usbC1, active: ["CC", "DisplayPort"], hotPlug: true, offers: [offer])]))[0]
    #expect(v.display && v.power.direction == .intoMac)
    #expect(v.mode == "powering the Mac + display")
}

@Test func secondChargerWaitsOnStandby() {
    let idle = PowerSourceEvidence(name: "USB-PD", maxMilliwatts: 30_000, winning: nil)
    let verdicts = classify(Snapshot(ports: [port(usbC1, offers: [appleCharger]), port(usbC2, offers: [idle])],
                                     macBatteryCharging: true))
    #expect(verdicts.map(\.power.direction) == [.intoMac, .standby])
}

@Test func tunneledDeviceJoinsTheThunderboltPort() {
    let ssd = device("Samsung T7", vendor: USBVendor.samsung, product: 0x4001, on: nil, speed: 10_000_000_000,
                     tunneled: true, [interface(0x08, 0x06, 0x62)])
    let verdicts = classify(Snapshot(ports: [port(usbC1, active: ["CC", "CIO"])], usbDevices: [ssd]))
    #expect(verdicts.count == 1)
    #expect(verdicts[0].thunderbolt && verdicts[0].data == [.storage])
}

@Test func untraceableDevicesAreKept() {
    let keyboard = device("Keyboard", vendor: 0x046D, product: 0xC31C, on: nil, speed: 1_500_000,
                          [interface(0x03, 0x01, 0x01)])
    let verdicts = classify(Snapshot(ports: [port(usbC1, attached: false)], usbDevices: [keyboard]))
    #expect(verdicts.map(\.port) == [usbC1, .unmapped])
    #expect(verdicts[1].data == [.input])
}

@Test func emptyPort() {
    let v = classify(Snapshot(ports: [port(usbC1, attached: false)]))[0]
    #expect(!v.attached && v.mode == "empty")
}

@Test(arguments: [
    (interface(0xFF, 0x42, 0x01), 0x18D1, DataFunction.debug),   // Android ADB
    (interface(0xE0, 0x01, 0x03), 0x04E8, .network),             // RNDIS tethering
    (interface(0x08, 0x06, 0x50), 0x0781, .storage),             // mass storage, bulk-only
    (interface(0xFF, 0xFE, 0x02), 0x1234, .vendor),              // usbmux's shape, but not Apple's
    (interface(0xFF, 0x00, 0x00, "MTP"), 0x04E8, .photos),       // Android MTP
    (interface(0xFF, 0x01, 0x00), 0x0403, .serial),              // FTDI bridge
])
func interfaceTable(_ i: USBInterfaceEvidence, vendor: Int, expected: DataFunction) {
    #expect(i.function(vendorID: vendor) == expected)
}

@Test func detachAndChangeEventsFire() {
    let watcher = PlugWatcher { _ in }
    let before = classify(Snapshot(ports: [port(usbC2, active: ["CC", "USB2"])], usbDevices: [iPhone],
                                   powerOut: [meterOnPort2]))
    let unplugged = classify(Snapshot(ports: [port(usbC2, attached: false)]))
    #expect(watcher.changes(from: before, to: unplugged, replugged: []).map(\.kind) == [.detached])
    let held = classify(Snapshot(ports: [port(usbC2, held: ["USB2"])], powerOut: [meterOnPort2]))
    #expect(watcher.changes(from: held, to: before, replugged: []).map(\.kind) == [.changed])
    #expect(watcher.changes(from: before, to: before, replugged: []).isEmpty)   // meter drift alone is silent
}
