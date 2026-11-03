// Copyright (c) 2022 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Cocoa

/// The window controller for showing tooltops.
public class TooltipController: NSWindowController {
    private var messageTextField: NSTextField
    private var effectView: NSVisualEffectView?
    private var tooltip: String = "" {
        didSet {
            messageTextField.stringValue = tooltip
            adjustSize()
        }
    }

    /// Creates a new instance.
    public init() {
        let contentRect = NSRect(x: 128.0, y: 128.0, width: 300.0, height: 20.0)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let panel = NSPanel(
            contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        panel.level = NSWindow.Level(Int(kCGPopUpMenuWindowLevel) + 1)
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        // Translucent blurred background that follows light/dark appearance.
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: contentRect.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 7
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur
        effectView = blur

        messageTextField = NSTextField()
        messageTextField.isEditable = false
        messageTextField.isSelectable = false
        messageTextField.isBezeled = false
        messageTextField.textColor = .labelColor
        messageTextField.drawsBackground = false
        messageTextField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        blur.addSubview(messageTextField)

        super.init(window: panel)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Present the tooltip window with a given text and a location.
    ///
    /// - Parameters:
    ///   - tooltip: The text to display.
    ///   - point: The origin of the window.
    @objc(showTooltip:atPoint:)
    public func show(tooltip: String, at point: NSPoint) {
        self.tooltip = tooltip
        window?.orderFront(nil)
        set(windowLocation: point)
    }

    /// Hide the tooltip window.
    @objc
    public func hide() {
        window?.orderOut(nil)
    }

    /// Set the location of the tooltip window.
    ///
    /// - Parameter windowTopLeftPoint: The givin origin.
    private func set(windowLocation windowTopLeftPoint: NSPoint) {

        var adjustedPoint = windowTopLeftPoint
        adjustedPoint.y -= 5

        var screenFrame = NSScreen.main?.visibleFrame ?? NSRect.zero
        for screen in NSScreen.screens {
            let frame = screen.visibleFrame
            if windowTopLeftPoint.x >= frame.minX && windowTopLeftPoint.x <= frame.maxX
                && windowTopLeftPoint.y >= frame.minY && windowTopLeftPoint.y <= frame.maxY
            {
                screenFrame = frame
                break
            }
        }

        let windowSize = window?.frame.size ?? NSSize.zero

        // bottom beneath the screen?
        if adjustedPoint.y - windowSize.height < screenFrame.minY {
            adjustedPoint.y = screenFrame.minY + windowSize.height
        }

        // top over the screen?
        if adjustedPoint.y >= screenFrame.maxY {
            adjustedPoint.y = screenFrame.maxY - 1.0
        }

        // right
        if adjustedPoint.x + windowSize.width >= screenFrame.maxX {
            adjustedPoint.x = screenFrame.maxX - windowSize.width
        }

        // left
        if adjustedPoint.x < screenFrame.minX {
            adjustedPoint.x = screenFrame.minX
        }

        window?.setFrameTopLeftPoint(adjustedPoint)

    }

    private func adjustSize() {
        let attrString = messageTextField.attributedStringValue
        var rect = attrString.boundingRect(
            with: NSSize(width: 1600.0, height: 1600.0), options: .usesLineFragmentOrigin)
        let padX: CGFloat = 8, padY: CGFloat = 4
        let size = NSSize(width: ceil(rect.width) + padX * 2, height: ceil(rect.height) + padY * 2)
        messageTextField.frame = NSRect(x: padX, y: padY, width: ceil(rect.width) + 2, height: ceil(rect.height))
        window?.setFrame(NSRect(origin: window?.frame.origin ?? .zero, size: size), display: true)
    }

}
