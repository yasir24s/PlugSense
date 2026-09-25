import Foundation
import PlugSenseKit

setvbuf(stdout, nil, _IOLBF, 0)   // line-buffered even when piped, so `watch` output streams

let arguments = CommandLine.arguments.dropFirst()
let json = arguments.contains("--json")
let why = arguments.contains("--why")
let command = arguments.first { !$0.hasPrefix("-") } ?? "status"

/// One port's verdict, flattened for JSON consumers.
struct Report: Encodable {
    var port: String
    var mode: String
    var details: String
    var verdict: PortVerdict

    init(_ verdict: PortVerdict) {
        port = verdict.port.description
        mode = verdict.mode
        details = verdict.details
        self.verdict = verdict
    }
}

struct EventReport: Encodable {
    var event: String
    var at: Date
    var now: Report
    var before: Report?
}

func emitJSON(_ value: some Encodable, pretty: Bool) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    do {
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    } catch {
        FileHandle.standardError.write(Data("plugsense: \(error)\n".utf8))
    }
}

/// Left-aligns `text` in a column of `width`, never truncating it.
func column(_ text: String, _ width: Int) -> String {
    text + String(repeating: " ", count: max(1, width - text.count))
}

func line(_ v: PortVerdict, why: Bool) -> String {
    let head = column(v.port.description, 12) + column(v.mode, 26) + v.details
    return why ? ([head] + v.reasons.map { "            \($0)" }).joined(separator: "\n") : head
}

switch command {
case "status":
    let verdicts = Classifier().classify(Probe.snapshot(waitingForAppleDevices: 3))
    if json { emitJSON(verdicts.map(Report.init), pretty: true) } else { verdicts.forEach { print(line($0, why: why)) } }

case "evidence":
    emitJSON(Probe.snapshot(waitingForAppleDevices: 3), pretty: true)

case "watch":
    let watcher = PlugWatcher { [json, why] event in
        if json {
            emitJSON(EventReport(event: event.kind.rawValue, at: Date(), now: Report(event.verdict),
                                 before: event.previous.map(Report.init)), pretty: false)
            return
        }
        let what = event.kind == .detached
            ? event.verdict.port.description + (event.previous.map { " — was \($0.mode): \($0.details)" } ?? "")
            : line(event.verdict, why: why)
        let time = Date().formatted(date: .omitted, time: .standard)
        print("\(time)  \(event.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))\(what)")
    }
    watcher.start()
    if !json {
        watcher.verdicts.forEach { print(line($0, why: why)) }
        print("— watching; plug something in (Ctrl-C to stop)")
    }
    RunLoop.main.run()

default:
    print("""
    usage: plugsense [status | watch | evidence] [--json] [--why]
      status    what every port is doing right now (default)
      watch     report plug, unplug and change events as they happen
      evidence  the raw registry and power readings the verdicts are made from
      --why     list the rules that fired for each port
    """)
    exit(command == "help" ? 0 : 2)
}
