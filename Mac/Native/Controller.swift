import AppKit
import SwiftUI
import ServiceManagement
import ApplicationServices
import OSLog

@MainActor final class DeskController: ObservableObject {
    @Published var displays: [DeskDisplay] = []
    @Published var selection: String {
        didSet {
            UserDefaults.standard.set(selection, forKey: "displayUUID")
            pendingSwitch = nil
            currentInput = nil
            updateHotKeys()
            if oldValue != selection { refresh() }
        }
    }
    @Published var currentInput: Int?
    @Published var busy = false
    @Published var refreshing = false
    @Published var accessibility = false
    @Published var shortcutsReady = false
    @Published var message = "Подключи MSI к MacBook через USB-C."
    @Published var lastError: String?
    @Published var loginEnabled = false
    @Published var loginNeedsApproval = false
    @Published var pageDownEnabled: Bool {
        didSet { UserDefaults.standard.set(pageDownEnabled, forKey: "pageDownEnabled"); updateHotKeys() }
    }
    @Published var switchKeyCode: Int {
        didSet { UserDefaults.standard.set(switchKeyCode, forKey: "switchKeyCode"); keys.reset(); updateHotKeys() }
    }
    @Published var windowsShortcutsEnabled: Bool {
        didSet { UserDefaults.standard.set(windowsShortcutsEnabled, forKey: "windowsShortcutsEnabled"); updateHotKeys() }
    }
    @Published var languageSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(languageSwitchEnabled, forKey: "languageSwitchEnabled"); updateHotKeys() }
    }
    @Published var lastLanguage = ""
    @Published var lastSwitchKey = ""
    @Published var paused = false { didSet { if paused { pendingSwitch = nil }; updateHotKeys() } }
    @Published var history: [String] = []
    private let keys = HotKeys()
    private let runner: CommandRunner
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var displayObserver: NSObjectProtocol?
    private var scheduledRefresh: Task<Void, Never>?
    private var lastSwitch = Date.distantPast
    private var pendingSwitch: (target: DeskTarget, displayID: String)?
    private var connectionGeneration = 0
    private let logger = Logger(subsystem: "ru.w1zardz.msi-deskswitch", category: "switch")

    var selectedDisplay: DeskDisplay? { displays.first { $0.id == selection } }
    var canSwitch: Bool { selectedDisplay != nil && !busy }
    var sourceLabel: String {
        switch currentInput {
        case 15: return "Сейчас выбран Windows"
        case 16: return "Сейчас выбран MacBook"
        case .some(let value): return "Другой вход монитора (\(value))"
        case nil: return selectedDisplay == nil ? "Монитор не выбран" : "Вход не подтверждён"
        }
    }

    init() {
        selection = UserDefaults.standard.string(forKey: "displayUUID") ?? ""
        pageDownEnabled = UserDefaults.standard.object(forKey: "pageDownEnabled") as? Bool ?? true
        let storedKey = UserDefaults.standard.integer(forKey: "switchKeyCode")
        switchKeyCode = storedKey == 116 ? 116 : 121
        windowsShortcutsEnabled = UserDefaults.standard.object(forKey: "windowsShortcutsEnabled") as? Bool ?? true
        languageSwitchEnabled = UserDefaults.standard.object(forKey: "languageSwitchEnabled") as? Bool ?? true
        runner = CommandRunner(executable: Bundle.main.resourceURL!.appendingPathComponent("m1ddc"))
        keys.onSwitch = { [weak self] in self?.switchTo(.windows) }
        keys.onError = { [weak self] in self?.report(DeskError.message($0)) }
        keys.onLanguageChanged = { [weak self] in self?.lastLanguage = $0 }
        keys.onSwitchKeyObserved = { [weak self] in self?.lastSwitchKey = $0 == 116 ? "PageUp" : "PageDown" }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidateConnection(); self?.keys.stop() }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keys.reset(); self?.checkPermissions(); self?.refreshSoon() }
            })
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateConnection(); self?.refreshSoon() }
            }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissions() }
        }
        checkPermissions()
        refresh()
    }

    func checkPermissions() {
        let wasTrusted = accessibility
        accessibility = AXIsProcessTrusted()
        if accessibility { keys.start() }
        else { keys.stop(); if wasTrusted { pendingSwitch = nil } }
        shortcutsReady = keys.isRunning
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        updateHotKeys()
    }

    private func updateHotKeys() {
        keys.enabled = selectedDisplay != nil && !paused && !busy
        keys.pageDownEnabled = pageDownEnabled
        keys.switchKeyCode = switchKeyCode
        keys.windowsShortcutsEnabled = windowsShortcutsEnabled && !paused
        keys.languageSwitchEnabled = languageSwitchEnabled && !paused
    }

    private func invalidateConnection() {
        connectionGeneration += 1
        pendingSwitch = nil
        displays = []
        currentInput = nil
        keys.reset()
        updateHotKeys()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            checkPermissions()
            if loginNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { report(error) }
    }

    func refreshSoon() {
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func refresh() {
        guard !busy, !refreshing else { refreshSoon(); return }
        refreshing = true
        let generation = connectionGeneration
        Task {
            defer {
                refreshing = false
                updateHotKeys()
                if let pending = pendingSwitch {
                    pendingSwitch = nil
                    if pending.displayID == selection { switchTo(pending.target) }
                }
            }
            do {
                let connected = DeskDisplay.parse(try await runner.run(["display", "list"]))
                guard generation == connectionGeneration else { refreshSoon(); return }
                displays = connected
                guard let selected = selectedDisplay else {
                    currentInput = nil
                    message = displays.isEmpty ? "MSI не найден. Проверь USB-C и разбуди монитор." : "Выбери MSI в настройках приложения."
                    return
                }
                let id = selected.id
                let response = try await runner.run(["display", id, "get", "input"])
                guard selection == id, generation == connectionGeneration else { refreshSoon(); return }
                let value = Int(response.trimmingCharacters(in: .whitespacesAndNewlines))
                currentInput = value.flatMap { (1...255).contains($0) ? $0 : nil }
                lastError = nil
                message = currentInput == nil ? "Монитор найден, но прочитать вход не удалось." : "Монитор готов к переключению."
            } catch {
                guard generation == connectionGeneration else { refreshSoon(); return }
                currentInput = nil
                report(error)
            }
        }
    }

    func switchTo(_ target: DeskTarget) {
        guard !busy, Date().timeIntervalSince(lastSwitch) > 1.5 else { return }
        do { _ = try DeskDisplay.requireSelection(selection, in: displays) }
        catch { report(error); return }
        if refreshing {
            pendingSwitch = (target, selection)
            message = "Проверяю подключение перед переходом на \(target.title)…"
            return
        }
        let selectedID = selection
        let generation = connectionGeneration
        lastSwitch = Date()
        busy = true
        lastError = nil
        message = "Переключаю на \(target.title)…"
        updateHotKeys()
        Task {
            defer { busy = false; updateHotKeys(); refreshSoon() }
            do {
                // Validate a fresh device list, never a stale ordinal or the first display.
                let connected = DeskDisplay.parse(try await runner.run(["display", "list"]))
                guard generation == connectionGeneration else { return }
                _ = try DeskDisplay.requireSelection(selectedID, in: connected)
                _ = try await runner.run(["display", selectedID, "set", "input", String(target.rawValue)])
                currentInput = nil
                message = "Команда \(target.title) отправлена. USB подключится через несколько секунд."
                record("Команда переключения → \(target.title)")
            } catch { report(error) }
        }
    }

    func copyDiagnostics() {
        let text = (["MSI DeskSwitch 2.0.0", ProcessInfo.processInfo.operatingSystemVersionString,
                     "Display: \(selectedDisplay?.name ?? "none")", "UUID: \(selection)",
                     "Input: \(currentInput.map(String.init) ?? "unknown")",
                     "Accessibility: \(accessibility); hotkeys: \(shortcutsReady)",
                     "PageDown: \(pageDownEnabled); paused: \(paused)",
                     "Switch key: \(switchKeyCode); Windows shortcuts: \(windowsShortcutsEnabled); AltShift: \(languageSwitchEnabled)",
                     "Last error: \(lastError ?? "none")"] + history).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        message = error.localizedDescription
        record("Ошибка: " + error.localizedDescription)
    }

    private func record(_ text: String) {
        history.insert(Date().formatted(date: .omitted, time: .standard) + "  " + text, at: 0)
        history = Array(history.prefix(20))
        logger.info("\(text, privacy: .public)")
    }
}
