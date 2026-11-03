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
            showCompletion(client: client)
            return false
        case .commitComposingThenLiteral:
            commitComposing(client: client)
            showCompletion(client: client)
            return false
        case .beginEnglish(let text):
            commitComposing(client: client)  // also drops the pending Zhuyin reading
            (client as? IMKTextInput)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            showCompletion(client: client)
            return true
        case .acceptOffer(let word):
            commitComposing(client: client)  // keeps the Chinese typed so far, drops the pending reading
            (client as? IMKTextInput)?.insertText(word, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            showBilingualTooltip(nil, client: client)
            return true
        case .insert(let text):
            (client as? IMKTextInput)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            showBilingualTooltip(nil, client: client)
            return true
        }
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

    private func showCompletion(client: Any!) {
        if let word = BilingualInput.shared.currentCompletion(composing: state is InputState.Inputting) {
            showBilingualTooltip(word + " ⇥", client: client)
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
