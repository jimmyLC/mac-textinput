import Carbon
import Foundation

let bundleID = "com.jimmylc.inputmethod.ZhuyinLM"
let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
let sources = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
func string(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let p = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}
func flag(_ source: TISInputSource, _ key: CFString) -> Bool {
    guard let p = TISGetInputSourceProperty(source, key) else { return false }
    return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
}
guard let parent = sources.first(where: { string($0, kTISPropertyInputSourceID) == bundleID }) else {
    fputs("FAIL: input method is not registered\n", stderr); exit(1)
}
guard let mode = sources.first(where: { string($0, kTISPropertyInputModeID) == bundleID + ".Bopomofo" }) else {
    fputs("FAIL: Bopomofo mode is not registered\n", stderr); exit(1)
}
guard flag(parent, kTISPropertyInputSourceIsEnabled) else {
    fputs("FAIL: input method parent is disabled; not available for selection\n", stderr); exit(1)
}
guard flag(mode, kTISPropertyInputSourceIsEnabled), flag(mode, kTISPropertyInputSourceIsSelectCapable) else {
    fputs("FAIL: Bopomofo mode is disabled or cannot be selected\n", stderr); exit(1)
}
print("OK: input method parent and selectable Bopomofo mode are enabled; typing still requires a UI test")
