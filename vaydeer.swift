// Small macOS tool for the Vaydeer JP-1011 keypad.
// Build: swiftc -O vaydeer.swift -o vaydeer
//
//   vaydeer info                     show firmware and layers
//   vaydeer dump                     show all keys
//   vaydeer backup <file.json>       save all keys to a file
//   vaydeer set [layer=N] 0=F13 1=ctrl+f16 ...  write keys (default: active layer)
//   vaydeer restore <file.json> [layer]         write keys back from a backup
//
// Key index is row by row: 0 1 2 / 3 4 5 / 6 7 8.
// Protocol notes come from the Vaydeer Studio project (docs/research/hid-protocol.md).

import Foundation
import IOKit.hid

let vendorID = 0x0483
let productID = 0x5752
let cmdWriteKey: UInt8 = 0x61
let cmdReadKey: UInt8 = 0x62
let cmdInfo: UInt8 = 0x60
let cmdLayerInfo: UInt8 = 0x63
let cmdWriteLayerName: UInt8 = 0x65
let cmdCommit: UInt8 = 0x66
let cmdReadLayerName: UInt8 = 0x67
// Only these commands can leave this program. Firmware command 0xFC is not here on purpose.
let allowedCommands: Set<UInt8> = [cmdInfo, cmdWriteKey, cmdReadKey, cmdLayerInfo, cmdWriteLayerName, cmdCommit, cmdReadLayerName]
// Vaydeer Studio validated writes on 1.0.2. Firmware 1.1.1 was added after a test on a real keypad.
let writeFirmwares: [[UInt8]] = [[1, 0, 2], [1, 1, 1]]
let writeBootloader: [UInt8] = [0, 2, 1]

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

func xor(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(0, ^) }
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

func utf16be(_ text: String) -> [UInt8] {
    text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
}

func fromUtf16be(_ bytes: [UInt8]) -> String {
    var units: [UInt16] = []
    var index = 0
    while index + 1 < bytes.count {
        units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        index += 2
    }
    return String(decoding: units, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
}

final class Keypad {
    private let manager: IOHIDManager // must stay alive, or the device closes
    private let device: IOHIDDevice
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    fileprivate var received: [[UInt8]] = []

    init() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
            kIOHIDPrimaryUsageKey: 1,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, set.count == 1, let found = set.first else {
            throw ToolError("Keypad command interface not found (need exactly one). Is the keypad connected?")
        }
        device = found
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            throw ToolError(String(format: "Cannot open keypad: 0x%08X", status))
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { context, _, _, _, _, report, length in
            let keypad = Unmanaged<Keypad>.fromOpaque(context!).takeUnretainedValue()
            keypad.received.append(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        pump(0.05) // drop old replies
        received.removeAll()
    }

    private func pump(_ seconds: Double) {
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, seconds, true)
    }

    private func parse(_ raw: [UInt8], expected: UInt8) -> [UInt8]? {
        for frame in [raw, Array(raw.dropFirst())] where frame.count >= 3 {
            let total = Int(frame[1]) + 3
            guard frame.count >= total, frame[0] == expected else { continue }
            guard xor(Array(frame[..<(total - 1)])) == frame[total - 1] else { continue }
            return Array(frame[2..<(total - 1)])
        }
        return nil
    }

    /// Sends one command. Returns the reply data after the status byte.
    func request(_ command: UInt8, _ payload: [UInt8] = []) throws -> [UInt8] {
        guard allowedCommands.contains(command) else {
            throw ToolError(String(format: "Command 0x%02X is not allowed", command))
        }
        guard payload.count <= 61 else { throw ToolError("Payload is too long") }
        let body = [command, UInt8(payload.count)] + payload
        var frame = body + [xor(body)]
        frame += [UInt8](repeating: 0, count: 64 - frame.count)
        received.removeAll()
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, frame, frame.count)
        guard status == kIOReturnSuccess else {
            throw ToolError(String(format: "Write to keypad failed: 0x%08X", status))
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            pump(0.01)
            for raw in received {
                if let data = parse(raw, expected: command) {
                    guard let first = data.first else { throw ToolError("Empty reply") }
                    guard first == 0 else {
                        throw ToolError(String(format: "Keypad refused command 0x%02X, status %d", command, first))
                    }
                    return Array(data.dropFirst())
                }
            }
        }
        throw ToolError(String(format: "No reply to command 0x%02X", command))
    }
}

struct Info {
    let type, keys: UInt8
    let firmware, bootloader: [UInt8]
    let activeLayer, layerCount, maxLayers: UInt8
}

struct Key: Codable, Equatable {
    var layer: Int
    var index: Int
    var keyType: Int
    var subtype: Int
    var encoding: Int
    var label: String
    var data: [Int]
}

struct Backup: Codable {
    var firmware: [Int]
    var bootloader: [Int]
    var activeLayer: Int
    var layerNames: [String]
    var keys: [Key]
}

func readInfo(_ pad: Keypad) throws -> Info {
    let data = try pad.request(cmdInfo)
    guard data.count >= 11 else { throw ToolError("Short info reply: \(hex(data))") }
    return Info(type: data[0], keys: data[1], firmware: Array(data[2...4]), bootloader: Array(data[5...7]),
                activeLayer: data[8], layerCount: data[9], maxLayers: data[10])
}

func readKey(_ pad: Keypad, layer: UInt8, index: UInt8) throws -> Key {
    let head = try pad.request(cmdReadKey, [0xFF, layer, index])
    guard head.count >= 4 else { throw ToolError("Short key header: \(hex(head))") }
    var data: [UInt8] = []
    var finished = false
    for sequence in 0..<16 {
        let chunk = try pad.request(cmdReadKey, [UInt8(sequence), layer, index])
        guard let first = chunk.first else { throw ToolError("Empty key data") }
        if first == 0xFE { finished = true; break }
        data += chunk.dropFirst()
    }
    guard finished else { throw ToolError("Key data has no end marker") }
    return Key(layer: Int(layer), index: Int(index), keyType: Int(head[1]), subtype: Int(head[2]),
               encoding: Int(head[3]), label: fromUtf16be(Array(head[4...])), data: data.map(Int.init))
}

func snapshot(_ pad: Keypad) throws -> Backup {
    let info = try readInfo(pad)
    var names: [String] = []
    var keys: [Key] = []
    for layer in 0..<info.layerCount {
        names.append(fromUtf16be(try pad.request(cmdReadLayerName, [layer])))
        for index in 0..<info.keys {
            keys.append(try readKey(pad, layer: layer, index: index))
        }
    }
    return Backup(firmware: info.firmware.map(Int.init), bootloader: info.bootloader.map(Int.init),
                  activeLayer: Int(info.activeLayer), layerNames: names, keys: keys)
}

func saveBackup(_ backup: Backup, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(backup).write(to: URL(fileURLWithPath: path))
}

func parseCodes(_ text: String) throws -> [UInt8] {
    var codes: [UInt8] = []
    for part in text.uppercased().split(separator: "+").map(String.init) {
        switch part {
        case "CTRL": codes.append(17)
        case "SHIFT": codes.append(16)
        case "ALT", "OPT", "OPTION": codes.append(18)
        case "CMD", "META": codes.append(91)
        default:
            if part.hasPrefix("F"), let number = Int(part.dropFirst()), (1...24).contains(number) {
                codes.append(UInt8(111 + number))
            } else if part.hasPrefix("NUM"), let number = Int(part.dropFirst(3)), (0...9).contains(number) {
                codes.append(UInt8(96 + number))
            } else {
                throw ToolError("Unknown key name: \(part)")
            }
        }
    }
    guard !codes.isEmpty else { throw ToolError("Empty key") }
    return codes
}

func describe(_ key: Key) -> String {
    let names = key.data.map { code -> String in
        switch code {
        case 16: return "Shift"
        case 17: return "Ctrl"
        case 18: return "Opt"
        case 91: return "Cmd"
        case 96...105: return "Num\(code - 96)"
        case 112...135: return "F\(code - 111)"
        default: return String(format: "0x%02X", code)
        }
    }
    return "key \(key.index): type=\(key.keyType) subtype=\(key.subtype) enc=\(key.encoding) "
        + "label=\"\(key.label)\" -> \(names.joined(separator: "+"))"
}

func writeKey(_ pad: Keypad, _ key: Key) throws {
    guard key.keyType == 0 || key.keyType == 1 else {
        throw ToolError("Key \(key.index) has type \(key.keyType). Only single keys and combinations can be written.")
    }
    let layer = UInt8(key.layer), index = UInt8(key.index)
    _ = try pad.request(cmdWriteKey, [0xFF, layer, index, UInt8(key.keyType), UInt8(key.subtype), 0] + utf16be(key.label))
    _ = try pad.request(cmdWriteKey, [0] + key.data.map { UInt8($0) })
    _ = try pad.request(cmdWriteKey, [0xFE])
}

func writeAll(_ pad: Keypad, keys: [Key], names: [String], info: Info) throws {
    guard writeFirmwares.contains(info.firmware), info.bootloader == writeBootloader, info.type == 1, info.keys == 9 else {
        throw ToolError("Firmware \(info.firmware) / bootloader \(info.bootloader) is not validated for writing. Nothing was written.")
    }
    for layer in Set(keys.map(\.layer)) {
        guard keys.filter({ $0.layer == layer }).map(\.index) == Array(0..<Int(info.keys)) else {
            throw ToolError("Layer \(layer) must be written with all keys in order. Nothing was written.")
        }
    }
    let maxIndex = UInt8(max(0, Int(info.maxLayers) - 1))
    for layer in Set(keys.map(\.layer)).sorted() {
        let value = UInt8(layer)
        _ = try pad.request(cmdWriteLayerName, [value, maxIndex] + utf16be(names[layer]))
        for key in keys where key.layer == layer { try writeKey(pad, key) }
        _ = try pad.request(cmdCommit, [value, maxIndex])
    }
    let after = try snapshot(pad)
    for key in keys {
        guard let actual = after.keys.first(where: { $0.layer == key.layer && $0.index == key.index }),
              actual.keyType == key.keyType, actual.data == key.data else {
            throw ToolError("Read-back differs on key \(key.index). Restore from the backup.")
        }
    }
    print("Written and verified by read-back: \(keys.count) keys.")
}

func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        throw ToolError("Use: info | dump | backup <file> | set 0=F13 ... | restore <file>")
    }
    let pad = try Keypad()
    let info = try readInfo(pad)
    switch command {
    case "info":
        print("type=\(info.type) keys=\(info.keys) firmware=\(info.firmware) bootloader=\(info.bootloader)")
        print("activeLayer=\(info.activeLayer) layerCount=\(info.layerCount) maxLayers=\(info.maxLayers)")
    case "dump":
        let all = try snapshot(pad)
        for (layer, name) in all.layerNames.enumerated() {
            print("Layer \(layer) \"\(name)\"\(layer == all.activeLayer ? " (active)" : "")")
            for key in all.keys where key.layer == layer { print("  " + describe(key)) }
        }
    case "backup":
        guard arguments.count == 2 else { throw ToolError("Use: backup <file>") }
        try saveBackup(try snapshot(pad), to: arguments[1])
        print("Saved \(arguments[1])")
    case "set":
        let all = try snapshot(pad)
        let stamp = Int(Date().timeIntervalSince1970)
        let path = "vaydeer-backup-\(stamp).json"
        try saveBackup(all, to: path)
        print("Backup: \(path)")
        var keys: [Key] = []
        var layer = all.activeLayer
        for item in arguments.dropFirst() {
            if item.hasPrefix("layer=") {
                guard let value = Int(item.dropFirst(6)), value < all.layerNames.count else {
                    throw ToolError("Bad layer: \(item)")
                }
                layer = value
                continue
            }
            let parts = item.split(separator: "=").map(String.init)
            guard parts.count == 2, let index = Int(parts[0]), (0..<Int(info.keys)).contains(index) else {
                throw ToolError("Bad item: \(item)")
            }
            let codes = try parseCodes(parts[1])
            guard var key = all.keys.first(where: { $0.layer == layer && $0.index == index }) else {
                throw ToolError("Key \(index) not found")
            }
            key.keyType = codes.count > 1 ? 1 : 0
            key.label = String(parts[1].uppercased().suffix(12)) // long labels are not stored
            key.data = codes.map(Int.init)
            keys.append(key)
        }
        // The keypad erases a layer when it is written, so always send all keys of the layer.
        let changed = keys
        let full = all.keys.filter { $0.layer == layer }.map { old in
            changed.first { $0.index == old.index } ?? old
        }
        try writeAll(pad, keys: full, names: all.layerNames, info: info)
    case "restore":
        guard (2...3).contains(arguments.count) else { throw ToolError("Use: restore <file> [layer]") }
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
        let only = arguments.count == 3 ? Int(arguments[2]) : nil
        let keys = backup.keys.filter { only == nil || $0.layer == only }
        try writeAll(pad, keys: keys, names: backup.layerNames, info: info)
    default:
        throw ToolError("Unknown command: \(command)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
