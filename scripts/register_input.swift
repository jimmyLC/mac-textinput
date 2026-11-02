import Carbon
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: register_input.swift /path/to/ZhuyinLM.app\n", stderr)
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.jimmylc.inputmethod.ZhuyinLM" else {
    fputs("Invalid ZhuyinLM bundle; nothing registered.\n", stderr)
    exit(1)
}
let status = TISRegisterInputSource(url as CFURL)
guard status == noErr else {
    fputs("Input source registration failed: \(status)\n", stderr)
    exit(1)
}
print("Registration request accepted; check activation separately.")
