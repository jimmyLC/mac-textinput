import Foundation

/// Holds uncommitted physical keys so a later classification never loses input.
struct BilingualCompositionBuffer {
    private(set) var rawKeys = ""

    mutating func append(_ key: Character) {
        rawKeys.append(key)
    }

    @discardableResult
    mutating func backspace() -> Bool {
        guard !rawKeys.isEmpty else { return false }
        rawKeys.removeLast()
        return true
    }

    /// Return the original text so the caller can decide whether and how to
    /// commit it. The caller must not invoke this until the client accepts it.
    mutating func take() -> String {
        let captured = rawKeys
        rawKeys = ""
        return captured
    }
}
