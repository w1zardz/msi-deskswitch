import AppKit
import ApplicationServices

final class HotKeys {
    var enabled = false
    var pageDownEnabled = true
    var switchKeyCode = 121
    var windowsShortcutsEnabled = false
    var languageSwitchEnabled = false
    var onSwitch: (() -> Void)?
    var onSwitchKeyObserved: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var onLanguageChanged: ((String) -> Void)?
    private var state = MonitorShortcutState()
    private var keyboard = WindowsKeyboardState()
    private var language = LanguageChordState()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.reset()
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let flags = event.flags
                var modifiers: KeyboardModifiers = []
                if flags.contains(.maskControl) { modifiers.insert(.control) }
                if flags.contains(.maskShift) { modifiers.insert(.shift) }
                if flags.contains(.maskAlternate) { modifiers.insert(.option) }
                if flags.contains(.maskCommand) { modifiers.insert(.command) }
                if type == .flagsChanged {
                    if owner.language.flagsChanged(modifiers, enabled: owner.languageSwitchEnabled) {
                        DispatchQueue.main.async {
                            do {
                                let name = try KeyboardInputSources.cycle()
                                owner.onLanguageChanged?(name)
                            }
                            catch { owner.onError?(error.localizedDescription) }
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
                let down = type == .keyDown
                let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if down && !repeated && (key == 116 || key == 121) {
                    DispatchQueue.main.async { owner.onSwitchKeyObserved?(key) }
                }
                owner.language.noteKey(key, down: down)
                let result = owner.state.handle(
                    key: key, down: down, repeated: repeated, modifiers: modifiers,
                    enabled: owner.enabled, pageDownEnabled: owner.pageDownEnabled,
                    switchKeyCode: owner.switchKeyCode)
                if result.trigger { DispatchQueue.main.async { owner.onSwitch?() } }
                if result.consume { return nil }
                let terminal = WindowsKeyboardState.isTerminal(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
                guard let translation = owner.keyboard.handle(key: key, down: down, repeated: repeated,
                    modifiers: modifiers, enabled: owner.windowsShortcutsEnabled, terminal: terminal) else {
                    return Unmanaged.passUnretained(event)
                }
                var translatedFlags = flags
                translatedFlags.subtract([.maskControl, .maskShift, .maskAlternate, .maskCommand])
                if translation.modifiers.contains(.control) { translatedFlags.insert(.maskControl) }
                if translation.modifiers.contains(.shift) { translatedFlags.insert(.maskShift) }
                if translation.modifiers.contains(.option) { translatedFlags.insert(.maskAlternate) }
                if translation.modifiers.contains(.command) { translatedFlags.insert(.maskCommand) }
                guard let replacement = CGEvent(keyboardEventSource: CGEventSource(event: event),
                                               virtualKey: CGKeyCode(translation.key), keyDown: down) else {
                    return Unmanaged.passUnretained(event)
                }
                replacement.flags = translatedFlags
                replacement.timestamp = event.timestamp
                replacement.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
                // CoreGraphics releases replacement events returned by a tap callback.
                return Unmanaged.passRetained(replacement)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { onError?("Не удалось включить горячие клавиши. Проверь Универсальный доступ и перезапусти DeskSwitch."); return }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    func reset() { state.reset(); keyboard.reset(); language.reset() }
    deinit { stop() }
}
