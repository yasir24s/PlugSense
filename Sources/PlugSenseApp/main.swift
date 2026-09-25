import AppKit

// `PlugSenseApp --render out.png` draws the popover and a sample popup from live readings, then
// exits: a way to look at the UI without screen-recording permission.
if let flag = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(flag + 1) {
    exit(Rendering.write(to: CommandLine.arguments[flag + 1]) ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon, even when run unbundled
app.run()
