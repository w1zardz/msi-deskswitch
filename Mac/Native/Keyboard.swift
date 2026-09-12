import Foundation
import Carbon

struct KeyboardModifiers: OptionSet, Equatable {
    let rawValue: UInt8
    static let control = KeyboardModifiers(rawValue: 1 << 0)
    static let shift = KeyboardModifiers(rawValue: 1 << 1)
    static let option = KeyboardModifiers(rawValue: 1 << 2)
    static let command = KeyboardModifiers(rawValue: 1 << 3)
}

// Retain the selected physical key until release, including when preferences change mid-press.
struct MonitorShortcutState {
    private var state = ShortcutState()
    private var owned: [Int: Int] = [:]

    mutating func reset() { state.reset(); owned.removeAll() }

    mutating func handle(key: Int, down: Bool, repeated: Bool, modifiers: KeyboardModifiers,
                         enabled: Bool, pageDownEnabled: Bool, switchKeyCode: Int) -> (consume: Bool, trigger: Bool) {
        let logical: Int
        if let captured = owned[key] { logical = captured }
        else if key == switchKeyCode && [116, 121].contains(switchKeyCode) { logical = 121 }
        else { logical = key == 121 ? -121 : key }
        let result = state.handle(key: logical, down: down, repeated: repeated,
                                  control: modifiers.contains(.control), shift: modifiers.contains(.shift),
                                  option: modifiers.contains(.option), command: modifiers.contains(.command),
                                  enabled: enabled, pageDownEnabled: pageDownEnabled)
        if down && result.consume { owned[key] = logical }
        if !down { owned.removeValue(forKey: key) }
        return result
    }
}

struct KeyboardTranslation: Equatable {
    let key: Int
    let modifiers: KeyboardModifiers
}

struct WindowsKeyboardState {
    private var owned: [Int: KeyboardTranslation] = [:]

    static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return ["com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
                "dev.warp.warp", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm"]
            .contains(bundleID) || bundleID.hasPrefix("dev.warp.warp-")
    }

    mutating func reset() { owned.removeAll() }

    mutating func handle(key: Int, down: Bool, repeated: Bool, modifiers: KeyboardModifiers,
                         enabled: Bool, terminal: Bool) -> KeyboardTranslation? {
        if !down { return owned.removeValue(forKey: key) }
        if let captured = owned[key] { return captured }
        guard enabled, !repeated, !modifiers.contains(.command), !modifiers.contains(.option) else { return nil }

        var targetKey = key
        var targetModifiers = modifiers
        if terminal {
            // Shell Control+C/R/D/etc. retain their native meaning.
            guard (key == 8 || key == 9), modifiers == [.control, .shift] else { return nil }
            targetModifiers = .command
        } else if modifiers.contains(.control) {
            targetModifiers.remove(.control)
            switch key {
            case 123, 124, 51, 117: targetModifiers.insert(.option) // Word navigation/deletion.
            case 115: targetKey = 126; targetModifiers.insert(.command) // Start of document.
            case 119: targetKey = 125; targetModifiers.insert(.command) // End of document.
            case 16: targetKey = 6; targetModifiers.formUnion([.command, .shift]) // Ctrl+Y -> redo.
            case 0, 1, 3, 6, 7, 8, 9, 13, 15, 17, 31, 35, 37, 45:
                targetModifiers.insert(.command)
            default: return nil
            }
        } else if key == 115 || key == 119 {
            targetKey = key == 115 ? 123 : 124
            targetModifiers.insert(.command)
        } else { return nil }
        let result = KeyboardTranslation(key: targetKey, modifiers: targetModifiers)
        owned[key] = result
        return result
    }
}

// Observe modifiers without suppressing their events or changing global modifier state.
// A gesture ends only after both modifiers are released; any other key cancels it.
struct LanguageChordState {
    private var heldKeys = Set<Int>()
    private var gesture = false
    private var chordSeen = false
    private var dirty = false

    mutating func reset() { heldKeys.removeAll(); gesture = false; chordSeen = false; dirty = false }

    mutating func noteKey(_ key: Int, down: Bool) {
        if down { heldKeys.insert(key); if gesture { dirty = true } }
        else { heldKeys.remove(key) }
    }

    mutating func flagsChanged(_ modifiers: KeyboardModifiers, enabled: Bool) -> Bool {
        if modifiers.isEmpty {
            let trigger = gesture && chordSeen && !dirty && enabled && heldKeys.isEmpty
            gesture = false; chordSeen = false; dirty = false
            return trigger
        }
        if !gesture { gesture = true; dirty = !heldKeys.isEmpty }
        if !enabled || modifiers.contains(.control) || modifiers.contains(.command) { dirty = true }
        if modifiers == [.option, .shift] { chordSeen = true }
        return false
    }
}

enum KeyboardInputSources {
    private static func string(_ source: TISInputSource, _ property: CFString) -> String? {
        guard let value = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
    }

    static func cycle() throws -> String {
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnabled as String: true,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue(),
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            throw DeskError.message("Не удалось прочитать раскладки macOS.")
        }
        let sources = list as! [TISInputSource]
        guard sources.count > 1 else {
            throw DeskError.message("Добавь вторую раскладку в Системных настройках → Клавиатура → Источники ввода.")
        }
        let currentID = string(current, kTISPropertyInputSourceID)
        let index = sources.firstIndex { string($0, kTISPropertyInputSourceID) == currentID }
        let next = sources[index.map { ($0 + 1) % sources.count } ?? 0]
        let result = TISSelectInputSource(next)
        guard result == noErr else { throw DeskError.message("macOS не переключила раскладку (\(result)).") }
        return string(next, kTISPropertyLocalizedName) ?? "Раскладка переключена"
    }
}
