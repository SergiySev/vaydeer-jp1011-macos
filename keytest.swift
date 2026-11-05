// Small window that shows which keys macOS really receives.
// Build: swiftc keytest.swift -o keytest
// Usage: keytest <log file> [seconds]
// It closes after F1..F9 with Ctrl+Option+Shift were all seen, or after the timeout.

import AppKit

let logPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "keytest.log"
let timeout = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 180 : 180
let fKeys: [UInt16: String] = [122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9"]

FileManager.default.createFile(atPath: logPath, contents: nil)
let log = FileHandle(forWritingAtPath: logPath)!
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Vaydeer key test"
let label = NSTextField(labelWithString: "Нажмите все 9 клавиш нампада")
label.font = .systemFont(ofSize: 22)
label.alignment = .center
label.maximumNumberOfLines = 0
label.frame = NSRect(x: 20, y: 30, width: 480, height: 160)
window.contentView?.addSubview(label)
window.center()
window.makeKeyAndOrderFront(nil)
window.level = .floating
app.activate(ignoringOtherApps: true)

var seen = Set<String>()
NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    var names: [String] = []
    if flags.contains(.control) { names.append("Ctrl") }
    if flags.contains(.option) { names.append("Opt") }
    if flags.contains(.shift) { names.append("Shift") }
    if flags.contains(.command) { names.append("Cmd") }
    names.append(fKeys[event.keyCode] ?? "code\(event.keyCode)")
    let text = names.joined(separator: "+")
    log.write(Data((text + "\n").utf8))
    if flags == [.control, .option, .shift], let key = fKeys[event.keyCode] { seen.insert(key) }
    label.stringValue = "\(text)\n\nГотово: \(seen.count) из 9"
    if seen.count == 9 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { app.terminate(nil) }
    }
    return nil
}
DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { app.terminate(nil) }
app.run()
