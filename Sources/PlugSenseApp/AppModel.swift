import AppKit
import PlugSenseKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController(model: model)
        model.start()
    }
}

/// The answer to "Use this connection for…". PlugSense can't enforce `dataOnly`, because the Mac
/// powers any device it exchanges data with; it watches instead, and says when the device charges.
enum ConnectionChoice: String {
    case chargeAndData, dataOnly
}

/// Live verdicts for the UI, fed by a `PlugWatcher` on the main queue.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var verdicts: [PortVerdict] = []
    @Published var expanded: Set<PortID> = []
    @Published var popUpOnPlug: Bool {
        didSet { UserDefaults.standard.set(popUpOnPlug, forKey: Self.popUpKey) }
    }
    /// Answers to "Use this connection for…", by `PortVerdict.deviceKey`.
    @Published private(set) var choices: [String: ConnectionChoice]
    var onVerdicts: (([PortVerdict]) -> Void)?
    var onEvent: ((PlugWatcher.Event) -> Void)?
    private var watcher: PlugWatcher?
    private static let popUpKey = "popUpOnPlug"
    private static let choicesKey = "connectionChoices"

    init() {
        popUpOnPlug = UserDefaults.standard.object(forKey: Self.popUpKey) as? Bool ?? true
        let saved = UserDefaults.standard.dictionary(forKey: Self.choicesKey) as? [String: String] ?? [:]
        choices = saved.compactMapValues(ConnectionChoice.init(rawValue:))
    }

    func choice(for verdict: PortVerdict) -> ConnectionChoice? {
        verdict.deviceKey.flatMap { choices[$0] }
    }

    /// Remembers `choice` for the device; nil forgets it, so the next plug-in asks again.
    func setChoice(_ choice: ConnectionChoice?, for deviceKey: String) {
        choices[deviceKey] = choice
        UserDefaults.standard.set(choices.mapValues(\.rawValue), forKey: Self.choicesKey)
    }

    func start() {
        let watcher = PlugWatcher(queue: .main, onUpdate: { [weak self] verdicts in
            MainActor.assumeIsolated { self?.show(verdicts) }
        }, onEvent: { [weak self] event in
            MainActor.assumeIsolated { self?.onEvent?(event) }
        })
        self.watcher = watcher
        watcher.start()
    }

    /// One look without watching, for --render.
    func load() {
        show(Classifier().classify(Probe.snapshot(waitingForAppleDevices: 3)))
    }

    func toggle(_ port: PortID) {
        if expanded.contains(port) { expanded.remove(port) } else { expanded.insert(port) }
    }

    /// Puts the raw evidence on the clipboard as JSON, for bug reports and fixtures.
    func copyEvidence() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Probe.snapshot()) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }

    private func show(_ verdicts: [PortVerdict]) {
        self.verdicts = verdicts
        onVerdicts?(verdicts)
    }
}
