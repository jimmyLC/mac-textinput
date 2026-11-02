// Renders the input-source menu icons (TIFF, 1x and 2x) from assets/icons/icon.svg.
// The system only reads bitmap/PDF menu icons, so the SVG is the source and TIFFs are generated.
// Usage: swift scripts/make_icons.swift assets/icons
import AppKit

func render(svg: NSImage, pixels: Int, png: Bool = false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return png ? rep.representation(using: .png, properties: [:])! : rep.tiffRepresentation!
}

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icons"
guard let svg = NSImage(contentsOfFile: "\(dir)/icon.svg") else { fatalError("cannot load \(dir)/icon.svg") }
// Both input modes share one menu icon.
for base in ["Bopomofo", "PlainBopomofo"] {
    for (suffix, px) in [("", 16), ("@2x", 32)] {
        try render(svg: svg, pixels: px).write(to: URL(fileURLWithPath: "\(dir)/\(base)\(suffix).tiff"))
    }
}
// App icon set, copied over the upstream AppIcon.appiconset at build time.
let appDir = "\(dir)/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: appDir, withIntermediateDirectories: true)
for px in [16, 32, 64, 128, 256, 512, 1024] {
    try render(svg: svg, pixels: px, png: true).write(to: URL(fileURLWithPath: "\(appDir)/\(px)X\(px).png"))
}
