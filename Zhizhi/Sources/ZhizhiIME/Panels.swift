import AppKit
import ZhizhiCore

/// A borderless translucent panel that floats beside the text without taking focus.
class FloatingPanel {
    let panel: NSPanel
    let blur = NSVisualEffectView()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 8
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur
    }

    func hide() { panel.orderOut(nil) }

    /// Places the panel under `lineRect` (screen coordinates), above it when there is no room.
    func place(size: NSSize, under lineRect: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.contains(lineRect.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: lineRect.minX, y: lineRect.minY - size.height - 4)
        if origin.y < visible.minY { origin.y = lineRect.maxY + 4 }
        if origin.x + size.width > visible.maxX { origin.x = visible.maxX - size.width }
        origin.x = max(origin.x, visible.minX)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }
}

/// Small tip beside the caret: the Tab offer or a mode change.
final class TipPanel: FloatingPanel {
    private let label = NSTextField(labelWithString: "")

    override init() {
        super.init()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        blur.addSubview(label)
    }

    func show(_ text: String, under lineRect: NSRect) {
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 16, height: ceil(label.frame.height) + 8)
        label.frame.origin = NSPoint(x: 8, y: 4)
        place(size: size, under: lineRect)
    }
}

/// The candidate list, vertical by default.
final class CandidatePanel: FloatingPanel {
    private final class ListView: NSView {
        var candidates: Session.Candidates?
        var font = NSFont.systemFont(ofSize: 16)
        var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let rowHeight: CGFloat = 26
        let width: CGFloat
        init(width: CGFloat) { self.width = width; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let list = candidates else { return }
            for (i, item) in list.items.enumerated() {
                let row = NSRect(x: 4, y: 4 + CGFloat(i) * rowHeight, width: width - 8, height: rowHeight)
                let selected = i == list.selected
                if selected {
                    NSColor.controlAccentColor.setFill()
                    NSBezierPath(roundedRect: row, xRadius: 5, yRadius: 5).fill()
                }
                let textColor: NSColor = selected ? .white : .labelColor
                let number = NSAttributedString(string: "\(i + 1)", attributes: [
                    .font: numberFont, .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor])
                number.draw(at: NSPoint(x: row.minX + 8, y: row.minY + 6))
                let text = NSAttributedString(string: item, attributes: [.font: font, .foregroundColor: textColor])
                text.draw(at: NSPoint(x: row.minX + 26, y: row.minY + 3))
            }
            if list.pageCount > 1 {
                let footer = NSAttributedString(string: "\(list.page + 1)/\(list.pageCount)", attributes: [
                    .font: numberFont, .foregroundColor: NSColor.secondaryLabelColor])
                footer.draw(at: NSPoint(x: width - footer.size().width - 10, y: 6 + CGFloat(list.items.count) * rowHeight))
            }
        }
    }

    private var view = ListView(width: 180)

    override init() {
        super.init()
        blur.addSubview(view)
    }

    func show(_ list: Session.Candidates, under lineRect: NSRect) {
        let font = view.font
        let widest = list.items.map { NSAttributedString(string: $0, attributes: [.font: font]).size().width }.max() ?? 40
        let width = max(120, ceil(widest) + 48)
        let height = CGFloat(list.items.count) * view.rowHeight + 8 + (list.pageCount > 1 ? 22 : 0)
        view.removeFromSuperview()
        view = ListView(width: width)
        view.candidates = list
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        blur.addSubview(view)
        place(size: NSSize(width: width, height: height), under: lineRect)
        view.needsDisplay = true
    }
}
