import Foundation
import UniformTypeIdentifiers

/// Why a device that reports its own battery isn't charging although it isn't full.
public enum ChargeHold: String, Codable, Sendable {
    /// Its charger is holding charge because the battery is too warm.
    case tooWarm = "too warm"
    /// Held for another reason, such as a charge limit or optimized charging. The device doesn't say which.
    case other
    /// Not settled yet: the heat counter updates only every ~20 s, so settling takes two looks.
    case checking
}

/// What a connected iPhone or iPad says about itself through lockdown, the service Finder syncs over.
public struct AppleDeviceReport: Codable, Sendable, Equatable {
    /// "iPhone18,2".
    public var productType: String
    /// BatteryCurrentCapacity, in percent. nil unless the device trusts this Mac.
    public var batteryPercent: Int?
    /// BatteryIsCharging. nil unless the device trusts this Mac.
    public var charging: Bool?
    /// FullyCharged.
    public var fullyCharged: Bool?
    /// Why it isn't charging, when it isn't and isn't full. Settled from its charger's heat counter.
    public var hold: ChargeHold?
    /// ChargerData.TimeChargingThermallyLimited: seconds its charging has been held or slowed for heat.
    public var thermalLimitSeconds: Int?
    /// ChargerData.NotChargingReason: the charger's own, undocumented code (256 while held for heat).
    public var notChargingReason: Int?

    /// The name macOS itself gives this model ("iPhone 17 Pro Max"), from CoreTypes' device-model-code tags.
    public var modelName: String? {
        UTType.types(tag: productType, tagClass: UTTagClass(rawValue: "com.apple.device-model-code"), conformingTo: nil)
            .lazy.compactMap(\.localizedDescription).first
    }

    /// The fastest USB link this model supports, in bits per second, where known.
    public var fastestUSB: Int? { Self.fastestUSB[productType] }

    /// USB-C iPhones and iPads by product type. Lightning and unlisted models stay unknown.
    static let fastestUSB: [String: Int] = {
        var table: [String: Int] = [:]
        for model in ["iPhone15,4", "iPhone15,5", "iPhone17,3", "iPhone17,4", "iPhone17,5", "iPhone18,3", "iPhone18,4"] {
            table[model] = 480_000_000           // iPhone 15/15 Plus, 16/16 Plus/16e, 17, Air
        }
        for model in ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2", "iPhone18,1", "iPhone18,2",
                      "iPad15,3", "iPad15,4", "iPad15,5", "iPad15,6"] {
            table[model] = 10_000_000_000        // 15 Pro, 16 Pro, 17 Pro (and Max); iPad Air (M3)
        }
        return table
    }()
}

/// One reading of a device's heat counter, kept to compare with the next.
struct ThermalSample: Equatable {
    var counter: Int
    var at: Date
    var hold: ChargeHold
}

extension ChargeHold {
    /// TimeChargingThermallyLimited counts seconds but moves in ~20 s steps (199, 299, 319, 599 were
    /// observed), so two readings must be at least this far apart to be compared.
    static let settleInterval: TimeInterval = 21

    /// Settles a hold from a new counter reading and the last kept sample: still counting means the
    /// charger is holding for heat now; flat means something else is holding it.
    static func settle(counter: Int, at now: Date, last: ThermalSample?) -> ThermalSample {
        guard let last else { return ThermalSample(counter: counter, at: now, hold: .checking) }
        guard now.timeIntervalSince(last.at) >= settleInterval else { return last }   // may not have ticked yet
        return ThermalSample(counter: counter, at: now, hold: counter > last.counter ? .tooWarm : .other)
    }
}

/// Keeps an `AppleDeviceReport` for every iPhone and iPad on USB, through MobileDevice.framework: the
/// private framework Finder uses. Read-only. It never pairs, so a device that hasn't trusted this Mac
/// reports its model and nothing else.
final class AppleDevices: @unchecked Sendable {   // `devices` and `thermal` live on `queue`; the rest behind `lock`
    static let shared = AppleDevices()

    private let api = MobileDeviceAPI()
    private let queue = DispatchQueue(label: "PlugSense.AppleDevices")
    private let lock = NSLock()
    private var reports: [String: AppleDeviceReport] = [:]   // by USB serial number
    private var observers: [@Sendable () -> Void] = []
    private var devices: [String: DeviceRef] = [:]            // retained, by USB serial number
    private var thermal: [String: ThermalSample] = [:]        // by USB serial number
    private var subscription: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?

    /// Starts listening. Call on the main thread: MobileDevice notifies on the subscribing run loop.
    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let api, subscription == nil else { return }
        var subscription: UnsafeMutableRawPointer?
        guard api.subscribe(mobileDeviceCallback, 0, 0, nil, &subscription) == 0 else { return }
        self.subscription = subscription
        // Battery levels change slowly, and each look is a lockdown session: every 30 s is plenty.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.lookAgain() }
        timer.resume()
        self.timer = timer
    }

    /// Calls `observer` (on a background queue) whenever any device's report changes.
    func observe(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(observer) }
    }

    /// The latest report for the USB device with this serial number (a UDID without its dash).
    func report(forUSBSerial serial: String) -> AppleDeviceReport? {
        lock.withLock { reports[Self.key(serial)] }
    }

    /// Spins the main run loop until every listed serial has a report, or `timeout` passes.
    func waitForReports(serials: [String], timeout: TimeInterval) {
        dispatchPrecondition(condition: .onQueue(.main))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !serials.allSatisfy({ report(forUSBSerial: $0) != nil }) {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    fileprivate func deviceNotified(_ info: UnsafeMutableRawPointer) {
        // struct am_device_notification_callback_info { am_device *dev; unsigned msg; ... }
        let message = info.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
        guard let api, let device = info.load(as: UnsafeMutableRawPointer?.self),
              api.interfaceType(device) == 1,   // USB; a device reached over Wi-Fi isn't on a port
              let udid = api.copyIdentifier(device)?.takeRetainedValue() as String? else { return }
        let key = Self.key(udid), ref = DeviceRef(pointer: device)
        switch message {
        case 1:   // connected
            api.retain(device)
            queue.async { [self] in
                devices.updateValue(ref, forKey: key).map { api.release($0.pointer) }
                look(at: ref, key: key)
            }
        case 2:   // disconnected
            queue.async { [self] in
                devices.removeValue(forKey: key).map { api.release($0.pointer) }
                thermal[key] = nil
                store(nil, for: key)
            }
        default:
            break
        }
    }

    private func lookAgain() {
        devices.forEach { look(at: $0.value, key: $0.key) }
    }

    private func lookAgain(at key: String) {
        if let ref = devices[key] { look(at: ref, key: key) }
    }

    /// One lockdown round trip for the model and, if the device trusts this Mac, its battery. On `queue`.
    private func look(at ref: DeviceRef, key: String) {
        guard let api, api.connect(ref.pointer) == 0 else { return }
        defer { _ = api.disconnect(ref.pointer) }
        guard let productType = api.copyValue(ref.pointer, nil, "ProductType" as CFString)?
            .takeRetainedValue() as? String else { return }
        var report = AppleDeviceReport(productType: productType)
        var charger: [String: Any]?
        // Battery values need a session, and a session needs an existing pairing. Never pair: that
        // would put a "Trust This Computer?" prompt on the device.
        if api.isPaired(ref.pointer) == 1, api.validatePairing(ref.pointer) == 0, api.startSession(ref.pointer) == 0 {
            defer { _ = api.stopSession(ref.pointer) }
            if let battery = api.copyValue(ref.pointer, "com.apple.mobile.battery" as CFString, nil)?
                .takeRetainedValue() as? [String: Any] {
                report.batteryPercent = battery["BatteryCurrentCapacity"] as? Int
                report.charging = battery["BatteryIsCharging"] as? Bool
                report.fullyCharged = battery["FullyCharged"] as? Bool
            }
            // Not charging, yet not full: ask its charger why.
            if report.charging == false, report.fullyCharged != true { charger = chargerData(ref.pointer) }
        }
        settleHold(&report, charger: charger, key: key)
        store(report, for: key)
        if report.hold == .checking {   // look again once the heat counter has had time to tick
            queue.asyncAfter(deadline: .now() + ChargeHold.settleInterval + 1) { [weak self] in self?.lookAgain(at: key) }
        }
    }

    private func settleHold(_ report: inout AppleDeviceReport, charger: [String: Any]?, key: String) {
        guard let charger, let counter = charger["TimeChargingThermallyLimited"] as? Int else {
            thermal[key] = nil
            return
        }
        let sample = ChargeHold.settle(counter: counter, at: Date(), last: thermal[key])
        thermal[key] = sample
        report.hold = sample.hold
        report.thermalLimitSeconds = counter
        report.notChargingReason = charger["NotChargingReason"] as? Int
    }

    /// The device's own AppleSmartBattery ChargerData, through the diagnostics relay (the service behind
    /// `idevicediagnostics`). Only "IORegistry" and "Goodbye" are ever sent. Needs a lockdown session.
    private func chargerData(_ device: UnsafeMutableRawPointer) -> [String: Any]? {
        guard let service = api?.service else { return nil }
        var connection: UnsafeMutableRawPointer?
        guard service.start(device, "com.apple.mobile.diagnostics_relay" as CFString, nil, &connection) == 0,
              let connection else { return nil }
        defer {
            _ = service.invalidate(connection)
            Unmanaged<AnyObject>.fromOpaque(connection).release()   // ours: +1 from the start call
        }
        let reply = request(["Request": "IORegistry", "EntryName": "AppleSmartBattery"], over: connection, service)
        _ = request(["Request": "Goodbye"], over: connection, service)
        let registry = (reply?["Diagnostics"] as? [String: Any])?["IORegistry"] as? [String: Any]
        return registry?["ChargerData"] as? [String: Any]
    }

    private func request(_ message: [String: Any], over connection: UnsafeMutableRawPointer,
                         _ service: MobileDeviceAPI.Service) -> [String: Any]? {
        guard service.send(connection, message as CFDictionary, .xmlFormat_v1_0) == 0 else { return nil }
        var reply: Unmanaged<CFPropertyList>?
        guard service.receive(connection, &reply, nil) == 0 else { return nil }
        return reply?.takeRetainedValue() as? [String: Any]
    }

    private func store(_ report: AppleDeviceReport?, for key: String) {
        let observers: [@Sendable () -> Void]? = lock.withLock {
            guard reports[key] != report else { return nil }
            reports[key] = report
            return self.observers
        }
        observers?.forEach { $0() }
    }

    static func key(_ serial: String) -> String {
        serial.replacingOccurrences(of: "-", with: "").uppercased()
    }
}

/// A MobileDevice device handle, moved between the main run loop and `AppleDevices.queue`.
private struct DeviceRef: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

private func mobileDeviceCallback(_ info: UnsafeMutableRawPointer?, _ context: UnsafeMutableRawPointer?) {
    guard let info else { return }
    AppleDevices.shared.deviceNotified(info)
}

private struct MissingSymbol: Error {}

private func symbol<T>(_ framework: UnsafeMutableRawPointer, _ name: String) throws -> T {
    guard let address = dlsym(framework, name) else { throw MissingSymbol() }
    return unsafeBitCast(address, to: T.self)
}

/// The MobileDevice.framework entry points PlugSense uses, looked up at run time. nil when the framework
/// or a core symbol is missing; PlugSense then simply has no device reports.
private struct MobileDeviceAPI: @unchecked Sendable {
    typealias Device = UnsafeMutableRawPointer
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void

    /// The service calls behind the heat check. Optional, so battery reports survive without them.
    struct Service {
        let start: @convention(c) (Device, CFString, CFDictionary?, UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
        let send: @convention(c) (UnsafeMutableRawPointer, CFPropertyList, CFPropertyListFormat) -> Int32
        let receive: @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Unmanaged<CFPropertyList>?>,
                                     UnsafeMutablePointer<CFPropertyListFormat>?) -> Int32
        let invalidate: @convention(c) (UnsafeMutableRawPointer) -> Int32

        init(_ framework: UnsafeMutableRawPointer) throws {
            start = try symbol(framework, "AMDeviceSecureStartService")
            send = try symbol(framework, "AMDServiceConnectionSendMessage")
            receive = try symbol(framework, "AMDServiceConnectionReceiveMessage")
            invalidate = try symbol(framework, "AMDServiceConnectionInvalidate")
        }
    }

    let subscribe: @convention(c) (Callback, UInt32, UInt32, UnsafeMutableRawPointer?,
                                   UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    let retain: @convention(c) (Device) -> Void
    let release: @convention(c) (Device) -> Void
    let connect: @convention(c) (Device) -> Int32
    let disconnect: @convention(c) (Device) -> Int32
    let isPaired: @convention(c) (Device) -> Int32
    let validatePairing: @convention(c) (Device) -> Int32
    let startSession: @convention(c) (Device) -> Int32
    let stopSession: @convention(c) (Device) -> Int32
    let copyValue: @convention(c) (Device, CFString?, CFString?) -> Unmanaged<CFTypeRef>?
    let copyIdentifier: @convention(c) (Device) -> Unmanaged<CFString>?
    let interfaceType: @convention(c) (Device) -> Int32
    let service: Service?

    init?() {
        let path = "/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        guard let framework = dlopen(path, RTLD_NOW) else { return nil }
        do {
            subscribe = try symbol(framework, "AMDeviceNotificationSubscribe")
            retain = try symbol(framework, "AMDeviceRetain")
            release = try symbol(framework, "AMDeviceRelease")
            connect = try symbol(framework, "AMDeviceConnect")
            disconnect = try symbol(framework, "AMDeviceDisconnect")
            isPaired = try symbol(framework, "AMDeviceIsPaired")
            validatePairing = try symbol(framework, "AMDeviceValidatePairing")
            startSession = try symbol(framework, "AMDeviceStartSession")
            stopSession = try symbol(framework, "AMDeviceStopSession")
            copyValue = try symbol(framework, "AMDeviceCopyValue")
            copyIdentifier = try symbol(framework, "AMDeviceCopyDeviceIdentifier")
            interfaceType = try symbol(framework, "AMDeviceGetInterfaceType")
        } catch {
            return nil
        }
        service = try? Service(framework)
    }
}
