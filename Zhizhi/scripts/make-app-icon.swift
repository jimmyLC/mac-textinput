// Renders the App icon from assets/icon.svg. Usage: swift scripts/make-app-icon.swift assets/icon.svg out.iconset
import AppKit

let args = CommandLine.arguments
guard let svg = NSImage(contentsOfFile: args[1]) else { fatalError("cannot load \(args[1])") }
let folder = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // The standard macOS icon shape: a rounded square inside a transparent margin.
        let inset = CGFloat(pixels) * 0.1
        let box = NSRect(x: inset, y: inset, width: CGFloat(pixels) - inset * 2, height: CGFloat(pixels) - inset * 2)
        NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225).addClip()
        svg.draw(in: box)
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
