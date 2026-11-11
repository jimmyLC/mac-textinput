import AppKit
import Carbon
import InputMethodKit
import ZhizhiCore

let bundleID = Bundle.main.bundleIdentifier ?? "com.jimmylc.inputmethod.Zhizhi"

// `Zhizhi --register` makes the input method known to the system without enabling it.
if CommandLine.arguments.contains("--register") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    print(status == noErr ? "registered" : "register failed: \(status)")
    exit(status == noErr ? 0 : 1)
}

autoreleasepool {
    _ = NSApplication.shared
    Engine.shared.load()
    let connection = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String ?? "Zhizhi_1_Connection"
    guard IMKServer(name: connection, bundleIdentifier: bundleID) != nil else {
        NSLog("Zhizhi: cannot start the input method server")
        exit(1)
    }
    NSApp.setActivationPolicy(.accessory)
    NSApp.run()
}
