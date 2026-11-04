import AppKit
import InputMethodKit
import ZhizhiCore

/// Translates system events into `Session` keys and applies its output to the app.
@objc(ZhizhiInputController)
final class ZhizhiInputController: IMKInputController {
    private static let candidates = CandidatePanel()
    private static let tip = TipPanel()

    private static var mode = TypingMode()   // shared, so English mode follows the user across apps

    private lazy var session = Session(decoder: Engine.shared.decoder)
    private var tipUntil: Date?

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged, .leftMouseDown]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        _ = Self.mode.syncCaps(NSEvent.modifierFlags.contains(.capsLock))
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
        Self.mode.otherInput()   // a Shift-click or Shift+key is not a lone Shift tap
        guard event.type == .keyDown else { return false }

        syncCaps(event, client: sender)
        if Self.mode.passesThrough {
            let flags = event.modifierFlags
            if flags.isDisjoint(with: [.command, .control, .option]),
               let letter = event.charactersIgnoringModifiers?.first,
               let text = Self.mode.lowercaseOverride(letter: letter, shift: flags.contains(.shift)) {
                insert(text, client: sender)
                return true
            }
            return false
        }

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
        syncCaps(event, client: client)
        switch Self.mode.flagsChanged(keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift), composing: session.isComposing) {
        case .flipSegment:
            let output = session.handle(.shiftTap)
            DebugLog.shared.record("key=shiftTap -> kinds=\(kinds())")
            apply(output, client: client)
        case .englishChanged(let on):
            DebugLog.shared.record("mode=\(on ? "english" : "chinese")")
            showModeTip(on ? "English" : "中文", client: client)
        default:
            break
        }
        return false
    }

    private func syncCaps(_ event: NSEvent, client: Any!) {
        guard case .capsChanged(let on)? = Self.mode.syncCaps(event.modifierFlags.contains(.capsLock)) else { return }
        DebugLog.shared.record("caps=\(on)")
        showModeTip(on ? "大寫" : "大寫關閉", client: client)
    }

    private func showModeTip(_ text: String, client: Any!) {
        if Self.mode.passesThrough {
            if let pending = session.flush() { insert(pending, client: client) }
            clearMarked(client)
        }
        Self.candidates.hide()
        Self.tip.show(text, under: lineRect(client: client))
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
