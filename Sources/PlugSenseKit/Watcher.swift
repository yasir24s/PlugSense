import Foundation
import IOKit
import IOKit.ps
import notify

/// Runs the protocol whenever something may have been plugged or unplugged, and reports each port
/// whose decision changed.
///
/// Registry notifications only say "something changed", so every trigger leads to the same step:
/// take a fresh snapshot, classify it, diff it against the last one. A poll backs the notifications
/// up, because some attaches only flip properties (a charge-only cable creates no new registry
/// objects) and the power meter refreshes on its own schedule.
public final class PlugWatcher: @unchecked Sendable {   // all mutable state is confined to `queue`
    public struct Event: Sendable {
        public enum Kind: String, Sendable { case attached, changed, detached }
        public var kind: Kind
        public var verdict: PortVerdict
        public var previous: PortVerdict?
    }

    /// Registry classes whose arrival or departure means some port's state probably changed.
    static let watchedClasses = ["IOUSBHostDevice", "IOPortTransportState", "IOPortFeaturePowerSource"]

    public private(set) var verdicts: [PortVerdict] = []
    private let classifier: Classifier
    private let queue: DispatchQueue
    private let pollInterval: TimeInterval
    private let onUpdate: (@Sendable ([PortVerdict]) -> Void)?
    private let onEvent: @Sendable (Event) -> Void
    private var notificationPort: IONotificationPortRef?
    private var registrations: [io_object_t] = []
    private var powerToken: Int32 = -1   // notify(3) tokens are never negative
    private var poll: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var connections: [PortID: String] = [:]
    private var plugTimes: [PortID: Date] = [:]

    /// Both callbacks run on `queue`: `onUpdate` after every look, with every port's verdict (meter
    /// readings included); `onEvent` for each port whose decision changed.
    public init(classifier: Classifier = Classifier(), queue: DispatchQueue = .main, pollInterval: TimeInterval = 2,
                onUpdate: (@Sendable ([PortVerdict]) -> Void)? = nil,
                onEvent: @escaping @Sendable (Event) -> Void) {
        self.classifier = classifier
        self.queue = queue
        self.pollInterval = pollInterval
        self.onUpdate = onUpdate
        self.onEvent = onEvent
    }

    deinit { stop() }

    /// Records what is already plugged in, without reporting it, and starts watching. Call on `queue`.
    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard notificationPort == nil else { return }
        refresh(reporting: false)

        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)
        notificationPort = port
        let context = Unmanaged.passUnretained(self).toOpaque()
        for className in Self.watchedClasses {
            for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var iterator: io_iterator_t = 0
                guard IOServiceAddMatchingNotification(port, kind, IOServiceMatching(className), registryChanged,
                                                       context, &iterator) == KERN_SUCCESS else { continue }
                drain(iterator)   // arms the notification
                registrations.append(iterator)
            }
        }
        // Port controllers are built in, so their general-interest messages can be subscribed once.
        registrations += Registry.each("IOPort") { entry, _ -> io_object_t? in
            var notification: io_object_t = 0
            let status = IOServiceAddInterestNotification(port, entry, kIOGeneralInterest, portMessage,
                                                          context, &notification)
            return status == KERN_SUCCESS ? notification : nil
        }
        notify_register_dispatch(kIOPSNotifyAnyPowerSource, &powerToken, queue) { [weak self] _ in
            self?.scheduleRefresh()
        }
        // iPhones and iPads report their own batteries; a changed report is a reason to look again.
        AppleDevices.shared.observe { [weak self] in
            guard let self else { return }
            queue.async { self.scheduleRefresh() }
        }
        if Thread.isMainThread { AppleDevices.shared.start() } else { DispatchQueue.main.async { AppleDevices.shared.start() } }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        poll = timer
    }

    public func stop() {
        poll?.cancel()
        poll = nil
        pending?.cancel()
        pending = nil
        if powerToken >= 0 {
            notify_cancel(powerToken)
            powerToken = -1
        }
        registrations.forEach { IOObjectRelease($0) }
        registrations = []
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
    }

    /// Coalesces a burst of triggers (one plug-in produces several) into one refresh.
    func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func refresh(reporting: Bool = true) {
        let snapshot = Probe.snapshot()
        var replugged: Set<PortID> = []
        for port in snapshot.ports {
            let connection = port.connectionActive ? port.connectionUUID ?? "attached" : nil
            if reporting, let connection, connections[port.id] != connection {
                plugTimes[port.id] = snapshot.takenAt
                replugged.insert(port.id)
                // Look again as the settle window closes, so "no data" is reported promptly.
                queue.asyncAfter(deadline: .now() + classifier.settleWindow + 0.1) { [weak self] in self?.refresh() }
            }
            if connection == nil { plugTimes[port.id] = nil }
            connections[port.id] = connection
        }
        let next = classifier.classify(snapshot, plugTimes: plugTimes, now: snapshot.takenAt)
        let events = reporting ? changes(from: verdicts, to: next, replugged: replugged) : []
        verdicts = next
        onUpdate?(next)
        events.forEach(onEvent)
    }

    func changes(from old: [PortVerdict], to new: [PortVerdict], replugged: Set<PortID>) -> [Event] {
        let before = Dictionary(old.map { ($0.port, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [Event] = []
        for verdict in new {
            let previous = before[verdict.port]
            switch (previous?.attached ?? false, verdict.attached) {
            case (false, true):
                events.append(Event(kind: .attached, verdict: verdict, previous: previous))
            case (true, false):
                events.append(Event(kind: .detached, verdict: verdict, previous: previous))
            case (true, true) where replugged.contains(verdict.port):   // swapped between two looks
                events.append(Event(kind: .attached, verdict: verdict, previous: previous))
            case (true, true) where previous?.decision != verdict.decision:
                events.append(Event(kind: .changed, verdict: verdict, previous: previous))
            default:
                break
            }
        }
        // The unmapped pseudo-port leaves the list entirely when its last device goes.
        for (id, previous) in before where previous.attached && !new.contains(where: { $0.port == id }) {
            events.append(Event(kind: .detached, verdict: .empty(id), previous: previous))
        }
        return events
    }
}

private func registryChanged(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    drain(iterator)
    guard let context else { return }
    Unmanaged<PlugWatcher>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
}

private func portMessage(_ context: UnsafeMutableRawPointer?, _ service: io_service_t, _ type: UInt32,
                         _ argument: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<PlugWatcher>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
}

private func drain(_ iterator: io_iterator_t) {
    while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
}
