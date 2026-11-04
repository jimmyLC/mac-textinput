import AppKit
import InputMethodKit
import ZhizhiCore

/// Translates system events into `Session` keys and applies its output to the app.
@objc(ZhizhiInputController)
final class ZhizhiInputController: IMKInputController {
    private static let candidates = CandidatePanel()
    private static let tip = TipPanel()

    private lazy var session = Session(decoder: Engine.shared.decoder)
    private var englishMode = false      // Caps Lock on: keys go straight to the app
    private var shiftDownAt: Date?       // left Shift held with nothing else pressed
    private var tipUntil: Date?

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        englishMode = NSEvent.modifierFlags.contains(.capsLock)
    }

    override func deactivateServer(_ sender: Any!) {
        finishComposition(sender)
    }

    override func commitComposition(_ sender: Any!) {
        finishComposition(sender)
    }

    private func finishComposition(_ client: Any!) {
        Self.candidates.hide()
        Self.tip.hide()
        if let text = session.flush() { insert(text, client: client) }
        clearMarked(client)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        if event.type == .flagsChanged { return handleFlags(event, client: sender) }
        guard event.type == .keyDown else { return false }
        shiftDownAt = nil

        let caps = event.modifierFlags.contains(.capsLock)
        if caps != englishMode { setEnglishMode(caps, client: sender) }
        if englishMode { return false }

        let key = translate(event)
        if !session.isComposing { session.setPreviousCharacter(characterBeforeCaret(client: sender)) }
        let output = session.handle(key)
        DebugLog.shared.record("key=\(Self.describe(key)) -> handled=\(output.handled) composing=\(session.isComposing) kinds=\(kinds()) commit=\(output.commit != nil)")
        apply(output, client: sender)
        return output.handled
    }

    private func kinds() -> String {
        session.composition.segments(Engine.shared.decoder).map { "\($0.kind)".prefix(2) }.joined(separator: ",")
    }

    private static func describe(_ key: Session.Key) -> String {
        switch key {
        case .character(let c): return c == " " ? "space" : String(c)
        case .fixedDigit(let c): return "fixed\(c)"
        default: return "\(key)"
        }
    }

    private func handleFlags(_ event: NSEvent, client: Any!) -> Bool {
        let caps = event.modifierFlags.contains(.capsLock)
        if caps != englishMode { setEnglishMode(caps, client: client) }
        guard event.keyCode == 56 else { shiftDownAt = nil; return false }   // left Shift only
        if event.modifierFlags.contains(.shift) {
            shiftDownAt = Date()
            return false
        }
        defer { shiftDownAt = nil }
        guard let down = shiftDownAt, Date().timeIntervalSince(down) < 1.0, session.isComposing else { return false }
        let output = session.handle(.shiftTap)
        DebugLog.shared.record("key=shiftTap -> kinds=\(kinds())")
        apply(output, client: client)
        return false
    }

    private func setEnglishMode(_ on: Bool, client: Any!) {
        englishMode = on
        if on, let text = session.flush() { insert(text, client: client) }
        if on { clearMarked(client) }
        Self.candidates.hide()
        DebugLog.shared.record("mode=\(on ? "english" : "chinese")")
        Self.tip.show(on ? "English" : "中文", under: lineRect(client: client))
        tipUntil = Date().addingTimeInterval(0.8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
            if let until = self?.tipUntil, Date() >= until { Self.tip.hide() }
        }
    }

    private func translate(_ event: NSEvent) -> Session.Key {
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) { return .shortcut }
        switch event.keyCode {
        case 36, 76: return .enter
        case 51: return .backspace
        case 48: return .tab
        case 53: return .escape
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 116: return .pageUp
        case 121: return .pageDown
        case 117, 115, 119: return .other     // forward delete, home, end
        default: break
        }
        if flags.contains(.option) {
            if let c = event.charactersIgnoringModifiers?.first, c.isNumber, c.isASCII { return .fixedDigit(c) }
            return .shortcut
        }
        guard let chars = event.characters, chars.count == 1, let c = chars.first else { return .other }
        if flags.contains(.numericPad), c.isNumber { return .fixedDigit(c) }
        guard c.isASCII, c.unicodeScalars.first!.value >= 0x20, c.unicodeScalars.first!.value < 0x7F else { return .other }
        return .character(c)
    }

    private func apply(_ output: Session.Output, client: Any!) {
        if let text = output.commit { insert(text, client: client) }
        if output.composing.isEmpty {
            clearMarked(client)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0]
            (client as? IMKTextInput)?.setMarkedText(
                NSAttributedString(string: output.composing, attributes: attributes),
                selectionRange: NSRange(location: output.caret, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        let rect = lineRect(client: client)
        if let list = output.candidates {
            Self.tip.hide()
            Self.candidates.show(list, under: rect)
        } else {
            Self.candidates.hide()
            if let offer = output.offer {
                tipUntil = nil
                Self.tip.show(offer + " ⇥", under: rect)
            } else if tipUntil == nil {
                Self.tip.hide()
            }
        }
    }

    private func insert(_ text: String, client: Any!) {
        (client as? IMKTextInput)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func clearMarked(_ client: Any!) {
        (client as? IMKTextInput)?.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                                 replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func lineRect(client: Any!) -> NSRect {
        var rect = NSRect(x: 0, y: 0, width: 0, height: 16)
        _ = (client as? IMKTextInput)?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        return rect
    }

    /// The character before the caret, when the app reports it.
    private func characterBeforeCaret(client: Any!) -> Character? {
        guard let text = client as? IMKTextInput else { return nil }
        let caret = text.selectedRange()
        guard caret.location != NSNotFound, caret.location > 0 else { return nil }
        return text.attributedSubstring(from: NSRange(location: caret.location - 1, length: 1))?.string.first
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "知之")
        let log = menu.addItem(withTitle: "記錄打字判斷（除錯用，24 小時後關閉）", action: #selector(toggleDebugLog(_:)), keyEquivalent: "")
        log.target = self
        log.state = DebugLog.shared.enabled ? .on : .off
        let clear = menu.addItem(withTitle: "清除記錄", action: #selector(clearDebugLog(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        menu.addItem(withTitle: "知之 \(version)（開發版）", action: nil, keyEquivalent: "")
        return menu
    }

    @objc private func toggleDebugLog(_ sender: Any?) { DebugLog.shared.enabled.toggle() }
    @objc private func clearDebugLog(_ sender: Any?) { DebugLog.shared.clear() }
}
