import AppKit

// Draws the 1200x630 share-preview image of the site: black and white, 知之輸入法.
// Usage: swift scripts/make-og-image.swift <out.png>
let size = NSSize(width: 1200, height: 630)
// Exactly 1200x630 pixels, whatever the screen's scale.
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 630, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

// A dot-matrix 知之 on the right, like the site's hero.
let mark = NSAttributedString(string: "知之", attributes: [
    .font: NSFont(name: "STSongti-TC-Black", size: 215) ?? NSFont.systemFont(ofSize: 215, weight: .black),
    .foregroundColor: NSColor.white])
let box = NSRect(x: 700, y: 170, width: 450, height: 300)
let layer = NSImage(size: box.size)
layer.lockFocus()
mark.draw(at: NSPoint(x: 6, y: 0))
layer.unlockFocus()
if let tiff = layer.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
    // lockFocus draws at the screen scale (2x on Retina): sample pixels, place dots in points.
    let scale = CGFloat(bitmap.pixelsWide) / box.width
    let step = Int(7 * scale)
    NSColor(white: 0.93, alpha: 1).setFill()
    for y in stride(from: step / 2, to: bitmap.pixelsHigh, by: step) {
        for x in stride(from: step / 2, to: bitmap.pixelsWide, by: step) {
            if let c = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y), c.alphaComponent > 0.4 {
                let r = 2.6 * c.alphaComponent
                NSBezierPath(ovalIn: NSRect(x: box.minX + CGFloat(x) / scale - r, y: box.minY + CGFloat(y) / scale - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }
}

func draw(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
}
let heavy = NSFont(name: "STSongti-TC-Black", size: 74) ?? NSFont.systemFont(ofSize: 74, weight: .black)
draw("專為 Mac 打造的", font: heavy, color: .white, at: NSPoint(x: 70, y: 400))
draw("注音輸入法", font: heavy, color: NSColor(white: 0.62, alpha: 1), at: NSPoint(x: 70, y: 310))
draw("中英混打不用切換 · AI 在你的電腦上運算", font: NSFont.systemFont(ofSize: 30, weight: .regular), color: NSColor(white: 0.78, alpha: 1), at: NSPoint(x: 70, y: 220))
draw("知之輸入法  Zhizhi", font: NSFont.systemFont(ofSize: 34, weight: .semibold), color: .white, at: NSPoint(x: 70, y: 70))
draw("免費使用", font: NSFont.systemFont(ofSize: 30, weight: .regular), color: NSColor(white: 0.62, alpha: 1), at: NSPoint(x: 1010, y: 72))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
