import Foundation
import Darwin

// This product profile is specifically for MSI MAG322UPF, matching Windows/DeskSwitch.cs.
enum DeskTarget: Int, CaseIterable {
    case windows = 15, mac = 16
    var title: String { self == .windows ? "Windows" : "MacBook" }
}

struct DeskDisplay: Identifiable, Equatable {
    let id: String
    let name: String

    static func parse(_ output: String) -> [DeskDisplay] {
        let pattern = #"^\[\d+\]\s+(.+?)\s+\(([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\)\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let idRange = Range(match.range(at: 2), in: line) else { return nil }
            let name = String(line[nameRange])
            let normalized = name.filter { !$0.isWhitespace }.uppercased()
            let id = String(line[idRange]).uppercased()
            guard normalized == "MSIMAG322UPF", seen.insert(id).inserted else { return nil }
            return DeskDisplay(id: id, name: name)
        }
    }

    static func requireSelection(_ id: String?, in displays: [DeskDisplay]) throws -> DeskDisplay {
        guard let id, let match = displays.first(where: { $0.id == id }) else {
            throw DeskError.message("Выбери подключённый MSI MAG322UPF в меню приложения.")
        }
        return match
    }
}

enum DeskError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

// Keep key-down ownership until key-up, even if modifiers/settings change meanwhile.
struct ShortcutState {
    private var captured = Set<Int>()
    mutating func reset() { captured.removeAll() }
    mutating func handle(key: Int, down: Bool, repeated: Bool, control: Bool,
                         shift: Bool, option: Bool, command: Bool,
                         enabled: Bool, pageDownEnabled: Bool) -> (consume: Bool, trigger: Bool) {
        if !down {
            let owned = captured.remove(key) != nil
            return (owned, owned && enabled)
        }
        if captured.contains(key) { return (true, false) }
        guard enabled, !repeated else { return (false, false) }
        let pageDown = key == 121 && pageDownEnabled && !control && !shift && !option && !command
        let fallback = key == 103 && control && shift && !option && !command
        guard pageDown || fallback else { return (false, false) }
        captured.insert(key)
        return (true, false)
    }
}

struct CommandRunner {
    let executable: URL

    func run(_ arguments: [String], timeout: TimeInterval = 8) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("deskswitch-" + UUID().uuidString)
                var handle: FileHandle?
                var watchdog: DispatchWorkItem?
                defer {
                    watchdog?.cancel()
                    try? handle?.close()
                    try? FileManager.default.removeItem(at: output)
                }
                do {
                    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                        throw DeskError.message("Не найден компонент управления монитором. Переустанови DeskSwitch.")
                    }
                    guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                                        attributes: [.posixPermissions: 0o600]) else {
                        throw DeskError.message("Не удалось создать временный файл диагностики.")
                    }
                    handle = try FileHandle(forWritingTo: output)
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardOutput = handle
                    process.standardError = handle
                    try process.run()
                    let deadline = DispatchWorkItem {
                        if process.isRunning {
                            process.terminate()
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            }
                        }
                    }
                    watchdog = deadline
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                    process.waitUntilExit()
                    deadline.cancel()
                    let reader = try FileHandle(forReadingFrom: output)
                    defer { try? reader.close() }
                    let data = try reader.read(upToCount: 65_536) ?? Data()
                    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                        throw DeskError.message(text.isEmpty
                            ? "Монитор не ответил. Проверь USB-C и DDC/CI в меню MSI."
                            : String(text.prefix(1200)))
                    }
                    continuation.resume(returning: text)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
