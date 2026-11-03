import Cocoa
import InputMethodKit

extension McBopomofoInputMethodController {
    /// Returns nil when the IME should handle the event as usual.
    func bilingualHandle(_ event: NSEvent, client: Any!) -> Bool? {
        let action = BilingualInput.shared.decide(event, composing: state is InputState.Inputting)
        if let label = BilingualInput.shared.modeLabel { showBilingualTooltip(label, client: client) }
        switch action {
        case .passThrough:
            return nil
        case .literal:
            spaceAfterChineseIfNeeded(client: client)
            showCompletion(client: client)
            return false
        case .commitComposingThenLiteral:
            commitComposing(client: client)
            spaceAfterChineseIfNeeded(client: client)
            showCompletion(client: client)
            return false
        case .beginEnglish(let text):
            commitComposing(client: client)  // also drops the pending Zhuyin reading
            spaceAfterChineseIfNeeded(client: client)
            (client as? IMKTextInput)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            showCompletion(client: client)
            return true
        case .acceptOffer(let word):
            commitComposing(client: client)  // keeps the Chinese typed so far, drops the pending reading
            spaceAfterChineseIfNeeded(client: client)
            (client as? IMKTextInput)?.insertText(word, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            showBilingualTooltip(nil, client: client)
            return true
        case .replaceTyped(let old, let new):
            replaceTyped(old: old, with: new, client: client)
            showBilingualTooltip(nil, client: client)
            return true
        case .repair(let backspaces, let keys):
            showBilingualTooltip(nil, client: client)
            for _ in 0..<backspaces { sendKey("\u{7F}", keyCode: 51, client: client) }
            for ch in keys { sendKey(ch, keyCode: Self.keyCodes[ch] ?? 0, client: client) }
            return true
        case .insert(let text):
            (client as? IMKTextInput)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            showBilingualTooltip(nil, client: client)
            return true
        }
    }

    /// When an English word starts right after Chinese text, put a space between them.
    private func spaceAfterChineseIfNeeded(client: Any!) {
        guard BilingualInput.shared.takeRunStart(), ScriptSpacing.enabled,
              let text = client as? IMKTextInput else { return }
        let caret = text.selectedRange()
        guard caret.location != NSNotFound, caret.location > 0,
              let previous = text.attributedSubstring(from: NSRange(location: caret.location - 1, length: 1))?.string.first,
              ScriptSpacing.needsSpace(before: previous) else { return }
        text.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    /// Commit the underlined composing text, keeping the Chinese the user already typed.
    private func commitComposing(client: Any!) {
        keyHandler.handleForceCommit(stateCallback: { self.handle(state: $0, client: client) })
        handle(state: InputState.Empty(), client: client)
    }

    /// Called after the IME handled a key itself: show the English offer beside the Zhuyin.
    func bilingualAfterKey(client: Any!) {
        showCompletion(client: client)
    }

    /// Replaces the text just before the caret when it is exactly `old` (checked first, so
    /// apps that do not report their text are left untouched).
    private func replaceTyped(old: String, with new: String, client: Any!) {
        guard let text = client as? IMKTextInput else { return }
        let caret = text.selectedRange()
        let length = (old as NSString).length
        guard caret.location != NSNotFound, caret.location >= length else { return }
        let range = NSRange(location: caret.location - length, length: length)
        guard text.attributedSubstring(from: range)?.string == old else { return }
        text.insertText(new, replacementRange: range)
    }

    /// Feeds a key through the normal handler, as if typed (used to retype fixed syllables).
    private func sendKey(_ ch: Character, keyCode: UInt16, client: Any!) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch),
            isARepeat: false, keyCode: keyCode) else { return }
        _ = handle(event, client: client)
    }

    /// US-layout virtual key codes for the keys that type Zhuyin.
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "-": 27, " ": 49,
    ]

    private func showCompletion(client: Any!) {
        let composing = state is InputState.Inputting
        if let word = BilingualInput.shared.currentCompletion(composing: composing) {
            showBilingualTooltip(word + " ⇥", client: client)
        } else if let spell = BilingualInput.shared.currentSpellFix {
            showBilingualTooltip("修正拼字：" + spell.new.trimmingCharacters(in: .whitespaces) + " ⇥", client: client)
        } else if let fix = BilingualInput.shared.currentRepair(composing: composing) {
            showBilingualTooltip("修正聲調：\(fix.word) ⇥", client: client)
        } else {
            showBilingualTooltip(nil, client: client)
        }
    }

    func showBilingualTooltip(_ text: String?, client: Any!) {
        guard let text = text else {
            if BilingualInput.shared.tooltipShown {
                BilingualInput.shared.tooltipShown = false
                McBopomofoInputMethodController.tooltipController.hide()
            }
            return
        }
        var rect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
        _ = (client as? IMKTextInput)?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        BilingualInput.shared.tooltipShown = true
        McBopomofoInputMethodController.tooltipController.show(
            tooltip: text, at: NSPoint(x: rect.origin.x, y: rect.origin.y - 4))
    }
}

extension McBopomofoInputMethodController {
    @objc func openUserDictionary(_ sender: Any?) {
        UserDictionaryWindowController.shared.present()
    }
}
