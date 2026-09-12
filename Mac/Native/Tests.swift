import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct CoreTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw TestFailure(description: message) }
    }

    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { checks += 1; return }
        throw TestFailure(description: message)
    }

    static func rejectsAsync(_ message: String, _ body: () async throws -> Void) async throws {
        do { try await body() }
        catch { checks += 1; return }
        throw TestFailure(description: message)
    }

    static func displaySelection() throws {
        let first = "11111111-2222-3333-4444-555555555555"
        let second = "ABCDEFAB-CDEF-ABCD-EFAB-CDEFABCDEFAB"
        let displays = DeskDisplay.parse("""
        [1] MSI MAG322UPF (\(first))
        [2] msi\tMAG 322UPF (\(second.lowercased()))
        [3] MSI MAG 322UPF (\(first))
        [4] Built-in Retina Display (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE)
        """)
        try expect(displays.count == 2, "Parse both supported spellings, deduplicate UUIDs, ignore other monitors")
        try expect(displays.map(\.id) == [first, second], "Normalize UUID case and preserve discovery order")
        try expect(displays.first?.name == "MSI MAG322UPF", "Preserve the real m1ddc display name")

        let invalid = """
        [1] MSI MAG322UPF EXTRA (\(first))
        [2] NOTMSI MAG322UPF (\(first))
        [3] MSI MAG322UPF2 (\(first))
        [4] MAG322UPF (\(first))
        [5] MSI MAG322UPF (not-a-uuid)
        [6] MSI MAG322UPF (\(first)) trailing data
        MSI MAG322UPF (\(first))
        """
        try expect(DeskDisplay.parse(invalid).isEmpty, "Reject lookalikes and malformed display records")
        try expect(DeskDisplay.parse("\r\n[1] MSI MAG 322UPF (\(first))\r\n").count == 1,
                   "Support CRLF and blank lines")
        try expect(DeskDisplay.parse("").isEmpty, "An empty discovery result must remain empty")
        let connected = DeskDisplay.parse("""
        [1] (null) (37D8832A-2D66-02CA-B9F7-8F30A301B230)
        [2] MSI MAG322UPF (D0137CE7-F454-42CB-8A10-DF4DCB131F4B)
        """)
        try expect(connected.map(\.id) == ["D0137CE7-F454-42CB-8A10-DF4DCB131F4B"],
                   "Recognize the attached MSI and ignore the Mac's unnamed display")
        let selected = try DeskDisplay.requireSelection(second, in: displays)
        try expect(selected.id == second, "Use the explicitly selected display rather than the first")
        try rejects("Multiple monitors require an explicit selection") {
            _ = try DeskDisplay.requireSelection(nil, in: displays)
        }
        try rejects("Even a single monitor requires an explicit selection") {
            _ = try DeskDisplay.requireSelection(nil, in: Array(displays.prefix(1)))
        }
        try rejects("Reject an unknown or disconnected selection") {
            _ = try DeskDisplay.requireSelection("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", in: displays)
        }
        try rejects("Reject an empty selection") { _ = try DeskDisplay.requireSelection("", in: displays) }
        try rejects("Reject an old selection when no monitor is connected") {
            _ = try DeskDisplay.requireSelection(first, in: [])
        }
        try expect(DeskTarget.windows.rawValue == 15 && DeskTarget.mac.rawValue == 16,
                   "Keep the physical input mapping compatible with Windows")
    }

    static func shortcuts() throws {
        var state = ShortcutState()
        func event(_ key: Int = 121, down: Bool, repeated: Bool = false,
                   control: Bool = false, shift: Bool = false, option: Bool = false,
                   command: Bool = false, enabled: Bool = true,
                   pageDownEnabled: Bool = true) -> (consume: Bool, trigger: Bool) {
            state.handle(key: key, down: down, repeated: repeated, control: control,
                         shift: shift, option: option, command: command,
                         enabled: enabled, pageDownEnabled: pageDownEnabled)
        }
        func result(_ actual: (consume: Bool, trigger: Bool), _ consume: Bool,
                    _ trigger: Bool, _ message: String) throws {
            try expect(actual.consume == consume && actual.trigger == trigger, message)
        }
        try result(event(down: true), true, false, "Capture PageDown without switching before release")
        try result(event(down: true, repeated: true), true, false, "Swallow held-key repeats without switching")
        try result(event(down: true), true, false, "Duplicate keydown must not switch")
        try result(event(down: false, control: true, shift: true), true, true,
                   "Own the keyup even if modifiers changed while the key was held")
        try result(event(down: false), false, false, "Only one release can trigger a handoff")
        try result(event(down: true, repeated: true), false, false, "Never capture an orphan repeated keydown")
        try result(event(down: false), false, false, "Orphan keyup must not trigger a handoff")

        for modifier in 0..<4 {
            try result(event(down: true, control: modifier == 0, shift: modifier == 1,
                             option: modifier == 2, command: modifier == 3), false, false,
                       "Modified PageDown remains available to other apps (modifier \(modifier))")
            try result(event(down: false), false, false, "Modified PageDown release remains unowned")
        }
        try result(event(down: true, pageDownEnabled: false), false, false, "Allow disabling bare PageDown")
        try result(event(down: false), false, false, "Enabling PageDown does not capture an existing release")
        try result(event(103, down: true, control: true, shift: true, pageDownEnabled: false), true, false,
                   "The fallback remains available when PageDown is disabled")
        try result(event(103, down: true, repeated: true, control: true, shift: true), true, false,
                   "A held fallback must not repeat")
        try result(event(103, down: false), true, true, "The fallback also switches only after release")
        for modifiers in [(false, true, false, false), (true, false, false, false),
                          (true, true, true, false), (true, true, false, true)] {
            try result(event(103, down: true, control: modifiers.0, shift: modifiers.1,
                             option: modifiers.2, command: modifiers.3), false, false,
                       "Require exactly Control+Shift for fallback")
        }
        try result(event(0, down: true, control: true, shift: true), false, false, "Ignore unrelated keys")
        try result(event(down: true, enabled: false), false, false, "Paused shortcuts leave keydown untouched")
        try result(event(down: false), false, false, "Resuming does not capture a key already held")
        try result(event(down: true), true, false, "Capture before pause")
        try result(event(down: true, repeated: true, enabled: false), true, false,
                   "Pausing retains ownership of held-key repeats")
        try result(event(down: false, enabled: false), true, false, "Consume the owned release while paused without switching")
        try result(event(down: false), false, false, "Resuming after release cannot trigger a delayed handoff")
        try result(event(down: true), true, false, "Capture before changing PageDown preference")
        try result(event(down: false, pageDownEnabled: false), true, true,
                   "Changing the preference mid-press preserves the captured key pair")
        try result(event(down: true), true, false, "Capture before reset")
        state.reset()
        try result(event(down: false), false, false, "Reset clears stale ownership after sleep or event-tap loss")
        try result(event(down: true), true, false, "New keys work after reset")
        try result(event(down: false), true, true, "Switching resumes after reset")
    }

    static func commandRunner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deskswitch-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("fake helper")
        let script = #"""
        #!/bin/sh
        case "$1" in
          success) printf '  accepted: %s\n' "$2" ;;
          failure) printf 'DDC rejected input\n' >&2; exit 7 ;;
          large) /usr/bin/awk 'BEGIN { for (i = 0; i < 262144; i++) printf "x" }' ;;
          timeout) trap '' TERM; while :; do :; done ;;
          *) exit 9 ;;
        esac
        """#
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let runner = CommandRunner(executable: helper)
        let value = try await runner.run(["success", "UUID with spaces; $(untouched)"])
        try expect(value == "accepted: UUID with spaces; $(untouched)",
                   "Preserve arguments literally and trim diagnostic whitespace")
        do {
            _ = try await runner.run(["failure"])
            throw TestFailure(description: "Nonzero helper exit must fail")
        } catch let failure as TestFailure { throw failure }
        catch {
            try expect(error.localizedDescription.contains("DDC rejected input"), "Include helper stderr on failure")
        }
        let large = try await runner.run(["large"], timeout: 5)
        try expect(large.utf8.count == 65_536 && large.allSatisfy { $0 == "x" },
                   "Drain output larger than a pipe buffer without blocking, and bound returned diagnostics")
        let start = Date()
        try await rejectsAsync("A helper ignoring termination must still time out") {
            _ = try await runner.run(["timeout"], timeout: 0.15)
        }
        try expect(Date().timeIntervalSince(start) < 5, "Enforce timeout even when the helper ignores SIGTERM")
        try await rejectsAsync("A missing helper must fail") {
            _ = try await CommandRunner(executable: directory.appendingPathComponent("missing")).run([])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: helper.path)
        try await rejectsAsync("A nonexecutable helper must fail") { _ = try await runner.run(["success"]) }
    }

    static func selectedSwitchKey() throws {
        var state = MonitorShortcutState()
        func key(_ code: Int, down: Bool, selected: Int, repeated: Bool = false,
                 modifiers: KeyboardModifiers = []) -> (consume: Bool, trigger: Bool) {
            state.handle(key: code, down: down, repeated: repeated, modifiers: modifiers,
                         enabled: true, pageDownEnabled: true, switchKeyCode: selected)
        }
        for selected in [121, 116] {
            let other = selected == 121 ? 116 : 121
            try expect(!key(other, down: true, selected: selected).consume,
                       "The unselected PageUp/PageDown key must remain usable")
            try expect(!key(other, down: false, selected: selected).trigger,
                       "An unselected key release must not switch")
            try expect(key(selected, down: true, selected: selected).consume,
                       "Capture the selected physical switch key")
            try expect(!key(selected, down: true, selected: selected, repeated: true).trigger,
                       "A held PageUp/PageDown must not switch")
            try expect(key(selected, down: false, selected: other).trigger,
                       "Changing the selected key mid-press still releases the original owner")
        }
        try expect(!key(121, down: true, selected: 42).consume, "Unknown key preference must not fall back to PageDown")
        _ = key(103, down: true, selected: 116, modifiers: [.control, .shift])
        try expect(key(103, down: false, selected: 116).trigger, "The fallback works with PageUp selected")
        _ = key(116, down: true, selected: 116)
        state.reset()
        try expect(!key(116, down: false, selected: 116).trigger, "Reset clears the physical switch-key mapping")
    }

    static func windowsKeyboard() throws {
        var state = WindowsKeyboardState()
        func key(_ code: Int, down: Bool = true, modifiers: KeyboardModifiers = .control,
                 repeated: Bool = false, enabled: Bool = true, terminal: Bool = false) -> KeyboardTranslation? {
            state.handle(key: code, down: down, repeated: repeated, modifiers: modifiers,
                         enabled: enabled, terminal: terminal)
        }
        let common = [0, 1, 3, 6, 7, 8, 9, 13, 15, 17, 31, 35, 37, 45]
        for code in common {
            for shift in [false, true] {
                let expected: KeyboardModifiers = shift ? [.command, .shift] : .command
                let original: KeyboardModifiers = shift ? [.control, .shift] : .control
                try expect(key(code, modifiers: original) == KeyboardTranslation(key: code, modifiers: expected),
                           "Translate common physical Control shortcut \(code), shift=\(shift)")
                try expect(key(code, down: false, modifiers: [], enabled: false, terminal: true)
                           == KeyboardTranslation(key: code, modifiers: expected),
                           "Keep the matching release after modifiers, app, or preference changed")
            }
        }
        try expect(key(16) == KeyboardTranslation(key: 6, modifiers: [.command, .shift]), "Ctrl+Y becomes Cmd+Shift+Z")
        try expect(key(16, down: false) == KeyboardTranslation(key: 6, modifiers: [.command, .shift]),
                   "Ctrl+Y releases Z rather than the original Y")
        for code in [123, 124, 51, 117] {
            try expect(key(code, modifiers: [.control, .shift]) == KeyboardTranslation(key: code, modifiers: [.option, .shift]),
                       "Preserve Shift in word navigation and word deletion")
            _ = key(code, down: false)
        }
        for (code, target) in [(115, 126), (119, 125)] {
            try expect(key(code) == KeyboardTranslation(key: target, modifiers: .command), "Control+Home/End targets the document")
            _ = key(code, down: false)
            let lineTarget = code == 115 ? 123 : 124
            try expect(key(code, modifiers: .shift) == KeyboardTranslation(key: lineTarget, modifiers: [.command, .shift]),
                       "Home/End targets the line and preserves selection")
            _ = key(code, down: false)
        }
        try expect(key(8, modifiers: .command) == nil, "Native Command shortcuts are untouched")
        try expect(key(8, modifiers: [.control, .option]) == nil, "Do not steal Control+Option app shortcuts")
        try expect(key(48) == nil, "Control+Tab remains native")
        try expect(key(2) == nil, "Unlisted Control shortcuts remain native")
        try expect(key(8, modifiers: []) == nil, "Normal typing is unchanged")
        try expect(key(8, enabled: false) == nil, "Disabled Windows mode leaves Control shortcuts unchanged")
        try expect(key(8, repeated: true) == nil, "Orphan repeats do not become new shortcuts")
        try expect(key(8, down: false) == nil, "Unowned releases are unchanged")
        let capture = key(8)
        try expect(key(8, modifiers: [], repeated: true, enabled: false) == capture,
                   "A held shortcut retains its mapping through repeats")
        state.reset()
        try expect(key(8, down: false) == nil, "Reset drops stale translated-key ownership")

        for code in [8, 15, 2, 51, 117, 115, 119, 123, 124] {
            try expect(key(code, terminal: true) == nil, "Terminal Control commands and editing are preserved")
        }
        for code in [8, 9] {
            try expect(key(code, modifiers: [.control, .shift], terminal: true)
                       == KeyboardTranslation(key: code, modifiers: .command),
                       "Control+Shift+C/V copies and pastes in terminals")
            _ = key(code, down: false)
        }
        try expect(key(115, modifiers: [], terminal: true) == nil, "Terminal Home remains Home")
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                   "dev.warp.Warp-Preview", "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm"] {
            try expect(WindowsKeyboardState.isTerminal(id), "Recognize terminal bundle \(id)")
        }
        try expect(!WindowsKeyboardState.isTerminal("com.apple.Safari") && !WindowsKeyboardState.isTerminal(nil),
                   "Regular applications do not receive terminal exceptions")
    }

    static func languageChord() throws {
        var state = LanguageChordState()
        func flags(_ value: KeyboardModifiers, enabled: Bool = true) -> Bool {
            state.flagsChanged(value, enabled: enabled)
        }
        try expect(!flags(.option), "Alt alone does not switch")
        try expect(!flags([.option, .shift]), "Wait for release of the language chord")
        try expect(!flags(.shift), "Releasing only Alt does not switch")
        try expect(flags([]), "A clean Alt+Shift chord switches once after both keys are released")
        try expect(!flags([]), "Repeated modifier-up events do not switch twice")
        _ = flags(.shift); _ = flags([.option, .shift]); _ = flags(.option)
        try expect(flags([]), "The reversed modifier press and release order also works")
        _ = flags(.shift)
        try expect(!flags([]), "Shift alone does not switch")
        _ = flags(.option)
        try expect(!flags([]), "Alt alone released does not switch")

        _ = flags(.option); _ = flags([.option, .shift])
        state.noteKey(8, down: true); state.noteKey(8, down: false)
        try expect(!flags([]), "Alt+Shift used with another shortcut does not change the layout")
        state.noteKey(8, down: true)
        _ = flags(.option); _ = flags([.option, .shift]); state.noteKey(8, down: false)
        try expect(!flags([]), "A key held before the chord cancels layout switching")
        _ = flags(.shift); state.noteKey(8, down: true); state.noteKey(8, down: false)
        _ = flags([.option, .shift])
        try expect(!flags([]), "Typing with Shift before adding Alt is not a clean gesture")
        _ = flags([.control, .option, .shift]); _ = flags([.option, .shift])
        try expect(!flags([]), "Using Control in the gesture cancels layout switching")
        _ = flags([.command, .option, .shift]); _ = flags([.option, .shift])
        try expect(!flags([]), "Using Command in the gesture cancels layout switching")
        _ = flags(.option, enabled: false); _ = flags([.option, .shift], enabled: false)
        try expect(!flags([]), "Enabling the preference during a held chord must not trigger it")
        _ = flags(.option); _ = flags([.option, .shift])
        try expect(!flags([], enabled: false), "Disabling the preference before release cancels the chord")
        _ = flags(.option); _ = flags([.option, .shift]); state.reset()
        try expect(!flags([]), "Reset prevents a stale chord after sleep or event-tap recovery")
        _ = flags(.option); _ = flags([.option, .shift]); _ = flags(.option); _ = flags([.option, .shift])
        try expect(flags([]) && !flags([]), "Repeated Shift while Alt is held produces only one layout switch")
    }

    static func main() async {
        do {
            try displaySelection()
            try shortcuts()
            try selectedSwitchKey()
            try windowsKeyboard()
            try languageChord()
            try await commandRunner()
            print("PASS: \(checks) checks for displays, handoff keys, Windows shortcuts, language gestures, and helper execution")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
