import Cocoa
import InputMethodKit

extension McBopomofoInputMethodController {
    /// Called after the IME has processed a key: offer an English completion next to the cursor.
    func bilingualAfterKey(client: Any!) {
        if state is InputState.Inputting, let word = BilingualInput.shared.liveEnglish() {
            let marked = NSAttributedString(string: word, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0])
            (client as? IMKTextInput)?.setMarkedText(
                marked, selectionRange: NSRange(location: word.count, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        guard state is InputState.Inputting, let word = BilingualInput.shared.currentCompletion() else {
            if BilingualInput.shared.tooltipShown {
                BilingualInput.shared.tooltipShown = false
                McBopomofoInputMethodController.tooltipController.hide()
            }
            return
        }
        var lineHeightRect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
        _ = (client as? IMKTextInput)?.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineHeightRect)
        BilingualInput.shared.tooltipShown = true
        McBopomofoInputMethodController.tooltipController.show(
            tooltip: word + " ⇥", at: NSPoint(x: lineHeightRect.origin.x, y: lineHeightRect.origin.y - 4))
    }

    /// Returns nil when the IME should handle the event as usual.
    func bilingualHandle(_ event: NSEvent, client: Any!) -> Bool? {
        switch BilingualInput.shared.decide(event, composing: state is InputState.Inputting) {
        case .passThrough:
            return nil
        case .toggled(let label):
            var rect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
            _ = (client as? IMKTextInput)?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            BilingualInput.shared.tooltipShown = true
            McBopomofoInputMethodController.tooltipController.show(
                tooltip: label, at: NSPoint(x: rect.origin.x, y: rect.origin.y - 4))
            return true
        case .literal:
            return false
        case .commitComposingThenLiteral:
            keyHandler.handleForceCommit(stateCallback: { self.handle(state: $0, client: client) })
            handle(state: InputState.Empty(), client: client)
            return false
        case .commit(let text):
            keyHandler.clear()
            handle(state: InputState.Committing(poppedText: text), client: client)
            handle(state: InputState.Empty(), client: client)
            return true
        case .replay(let head, let text):
            keyHandler.clear()
            handle(state: InputState.Empty(), client: client)
            for ch in head {
                guard let ascii = ch.asciiValue else { continue }
                let input = KeyHandlerInput(inputText: String(ch), keyCode: 0, charCode: UInt16(ascii),
                                            flags: [], isVerticalMode: false)
                _ = keyHandler.handle(input: input, state: state, stateCallback: { self.handle(state: $0, client: client) },
                                      errorCallback: {})
            }
            keyHandler.handleForceCommit(stateCallback: { self.handle(state: $0, client: client) })
            handle(state: InputState.Committing(poppedText: text), client: client)
            handle(state: InputState.Empty(), client: client)
            return true
        }
    }
}
