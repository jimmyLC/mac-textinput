// Renders the input-menu icon from assets/icon.svg. Usage: swift scripts/make-icon.swift assets/icon.svg out.tiff
import AppKit

let args = CommandLine.arguments
guard let svg = NSImage(contentsOfFile: args[1]) else { fatalError("cannot load \(args[1])") }
let output = NSImage(size: NSSize(width: 16, height: 16))
for pixels in [16, 32] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 16, height: 16)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    svg.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
    NSGraphicsContext.restoreGraphicsState()
    output.addRepresentation(rep)
}
try output.tiffRepresentation!.write(to: URL(fileURLWithPath: args[2]))
