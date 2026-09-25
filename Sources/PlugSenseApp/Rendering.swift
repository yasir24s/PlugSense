import AppKit
import SwiftUI
import PlugSenseKit

/// Draws the popover (every attached port expanded) beside the popup a plug-in would raise, from
/// live readings, into a PNG.
@MainActor
enum Rendering {
    static func write(to path: String) -> Bool {
        let model = AppModel()
        model.load()
        // A charging hold settles on the device's next heat-counter update, at least 21 s after the first look.
        if model.verdicts.contains(where: { $0.chargeHold == .checking }) {
            Thread.sleep(forTimeInterval: 24)
            model.load()
        }
        let attached = model.verdicts.filter(\.attached)
        model.expanded = Set(attached.map(\.port))
        // The popup as a plug-in would raise it: the question, if a device that can be asked is plugged in,
        // and beside it a sample of the warning "Data only" leads to if that device starts charging. The
        // popup holds one row per port, so the sample is a popup of its own.
        let popup = PopupModel(), warning = PopupModel()
        if let asked = attached.last(where: \.canAskChargeOrData) {
            popup.items = [.init(style: .question, verdict: asked, previous: nil, choice: nil, expires: .distantFuture)]
            var charging = asked
            charging.charge = .charging
            charging.batteryPercent = 96
            warning.items = [.init(style: .chargingWarning, verdict: charging, previous: nil, choice: .dataOnly,
                                   expires: .distantFuture)]
        } else if let last = attached.last {
            popup.items = [.init(style: .news(.attached), verdict: last, previous: nil, choice: nil,
                                 expires: .distantFuture)]
        }
        let sheet = HStack(alignment: .top, spacing: 24) {
            PopoverView(model: model, rendering: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 16) {
                if !popup.items.isEmpty { PopupView(popup: popup, rendering: true) }
                if !warning.items.isEmpty { PopupView(popup: warning, rendering: true) }
            }
        }
        .padding(24)
        .background(Color(nsColor: .underPageBackgroundColor))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            FileHandle.standardError.write(Data("render: \(error)\n".utf8))
            return false
        }
    }
}
