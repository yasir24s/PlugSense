// Draws PlugSense's app icon: a USB-C port crossed by a lightning bolt, on a blue-to-green squircle
// (the app's colors for data and for charging). Everything is drawn here, with no SF Symbols, whose
// license rules out app icons.
//
//   swift scripts/make-icon.swift                      writes Resources/AppIcon.icns
//   swift scripts/make-icon.swift --preview out.png    writes a sheet of every size, to check legibility
import AppKit
import SwiftUI

/// A lightning bolt in a unit box.
struct Bolt: Shape {
    func path(in r: CGRect) -> Path {
        let points: [(CGFloat, CGFloat)] = [(0.62, 0), (0.06, 0.58), (0.45, 0.58), (0.36, 1), (0.94, 0.40), (0.55, 0.40)]
        var path = Path()
        path.move(to: CGPoint(x: r.minX + points[0].0 * r.width, y: r.minY + points[0].1 * r.height))
        for (x, y) in points.dropFirst() { path.addLine(to: CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)) }
        path.closeSubpath()
        return path
    }
}

/// The icon on a 1024-point canvas, following the macOS grid: an 824-point squircle, 100 points in.
struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.36, blue: 0.90),
                                              Color(red: 0.06, green: 0.72, blue: 0.55)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            // The port, with a gap cut around the bolt so the bolt reads at small sizes.
            ZStack {
                Capsule().strokeBorder(.white, lineWidth: 46).frame(width: 600, height: 236)
                Capsule().fill(.white).frame(width: 380, height: 58)
                Bolt().stroke(.black, style: StrokeStyle(lineWidth: 64, lineJoin: .round))
                    .frame(width: 230, height: 400)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            Bolt().fill(Color(red: 1.0, green: 0.84, blue: 0.10)).frame(width: 230, height: 400)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func png(_ view: some View, pixels: Int) -> Data {
    let renderer = ImageRenderer(content: view)
    renderer.scale = CGFloat(pixels) / 1024
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("could not render the icon at \(pixels) px")
    }
    return data
}

@MainActor func preview(to path: String) {
    let sizes = [512, 128, 64, 32, 16]
    let row = HStack(alignment: .bottom, spacing: 28) {
        ForEach(sizes, id: \.self) { size in
            Image(nsImage: NSImage(data: png(Icon(), pixels: size * 2))!)
                .resizable().interpolation(.high).frame(width: CGFloat(size), height: CGFloat(size))
        }
    }
    let sheet = VStack(spacing: 0) {
        row.padding(28).background(Color(white: 0.96))
        row.padding(28).background(Color(white: 0.12))
    }
    try! png(sheet, pixels: 1024).write(to: URL(fileURLWithPath: path))   // the sheet's own scale is fine here
}

@MainActor func icns(to path: String) throws {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try png(Icon(), pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
        try png(Icon(), pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", path]
    try iconutil.run()
    iconutil.waitUntilExit()
    try? FileManager.default.removeItem(at: iconset)
    guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
}

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--preview"), arguments.indices.contains(flag + 1) {
        preview(to: arguments[flag + 1])
    } else {
        try! FileManager.default.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
        try! icns(to: "Resources/AppIcon.icns")
        print("wrote Resources/AppIcon.icns")
    }
}
