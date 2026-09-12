import AppKit
import ApplicationServices

final class HotKeys {
    var enabled = false
    var pageDownEnabled = true
    var switchKeyCode = 121
    var windowsShortcutsEnabled = false
    var languageSwitchEnabled = false
    var headphonesEnabled = false { didSet { if oldValue != headphonesEnabled { invalidateVolumeCallbacks() } } }
    var onHeadphonesAction: ((HeadphonesAction) -> Void)?
    var onSwitch: (() -> Void)?
    var onSwitchKeyObserved: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var onLanguageChanged: ((String) -> Void)?
    private var state = MonitorShortcutState()
    private var keyboard = WindowsKeyboardState()
    private var language = LanguageChordState()
    private var volume = VolumeKeyState()
    private var volumeEpoch = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << 14) // NSEvent.systemDefined: multimedia volume keys.
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    owner.reset()
                    if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                if type.rawValue == 14 {
                    guard let native = NSEvent(cgEvent: event), native.subtype.rawValue == 8 else {
                        return Unmanaged.passUnretained(event)
                    }
                    let data = native.data1
                    let key = (data >> 16) & 0xffff
                    let phase = (data >> 8) & 0xff
                    guard phase == 0x0a || phase == 0x0b else { return Unmanaged.passUnretained(event) }
                    let down = phase == 0x0a
                    owner.language.noteKey(0x1000 + key, down: down)
                    let result = owner.volume.handle(key: key, down: down, repeated: data & 1 != 0,
                                                     enabled: owner.headphonesEnabled)
                    if let action = result.action { owner.deliverVolume(action) }
                    return result.consume ? nil : Unmanaged.passUnretained(event)
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
                // Some keyboard drivers emit the equivalent virtual keys instead of NX events.
                if let media = [72: 0, 73: 1, 74: 7][key] {
                    owner.language.noteKey(key, down: down)
                    let result = owner.volume.handle(key: media, down: down, repeated: repeated,
                                                     enabled: owner.headphonesEnabled)
                    if let action = result.action { owner.deliverVolume(action) }
                    if result.consume { return nil }
                }
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

    func invalidateVolumeCallbacks() { volumeEpoch += 1; volume.invalidate() }
    private func deliverVolume(_ action: HeadphonesAction) {
        let token = volumeEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.volumeEpoch == token, self.headphonesEnabled else { return }
            self.onHeadphonesAction?(action)
        }
    }
    func reset() { state.reset(); keyboard.reset(); language.reset(); volume.reset(); invalidateVolumeCallbacks() }
    deinit { stop() }
}
