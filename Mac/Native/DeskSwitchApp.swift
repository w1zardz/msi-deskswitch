import AppKit
import SwiftUI

@main struct DeskSwitchApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = DeskAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class DeskAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var controller: DeskController!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DeskController()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "DeskSwitch")
        item.button?.toolTip = "DeskSwitch — Mac ↔ Windows"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if !controller.accessibility || controller.selection.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showSettings() }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.checkPermissions()
        menu.removeAllItems()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: controller.busy ? "Переключение…" :
            (controller.selectedDisplay?.name ?? "MSI не подключён или не выбран"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add("Перейти в Windows", action: #selector(windows), icon: "pc", enabled: controller.canSwitch, to: menu)
        add("Показать MacBook на MSI", action: #selector(mac), icon: "laptopcomputer", enabled: controller.canSwitch, to: menu)
        menu.addItem(.separator())
        if !controller.accessibility {
            add("Включить клавиатуру…", action: #selector(showSettings), icon: "keyboard", to: menu)
        } else {
            let pause = add("Пауза клавиатурных функций", action: #selector(pauseKeys), to: menu)
            pause.state = controller.paused ? .on : .off
        }
        add("Настройки…", action: #selector(showSettings), icon: "gearshape", to: menu)
        menu.addItem(.separator())
        add("Выйти из DeskSwitch", action: #selector(quit), to: menu)
        controller.refresh()
    }

    @discardableResult private func add(_ title: String, action: Selector, icon: String? = nil,
                                        enabled: Bool = true, to menu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        entry.isEnabled = enabled
        if let icon { entry.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        menu.addItem(entry)
        return entry
    }

    @objc private func windows() { controller.switchTo(.windows) }
    @objc private func mac() { controller.switchTo(.mac) }
    @objc private func pauseKeys() { controller.paused.toggle() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 660),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "DeskSwitch"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: DeskSettings(model: controller))
            window.setContentSize(NSSize(width: 480, height: 660))
            settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            let width = min(CGFloat(480), frame.width - 32)
            let height = min(CGFloat(688), frame.height - 32)
            window.setFrame(NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2,
                width: width, height: height), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.checkPermissions()
        controller.refresh()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }
}

struct DeskSettings: View {
    @ObservedObject var model: DeskController
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "display.2").font(.system(size: 30)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MacBook ↔ Windows").font(.system(size: 20, weight: .semibold))
                        Text("Один экран и привычная клавиатура.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Переключение компьютера").fontWeight(.semibold)
                            Spacer()
                            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).disabled(model.busy || model.refreshing)
                                .help("Найти монитор").accessibilityLabel("Найти монитор")
                        }
                        Picker("Монитор", selection: $model.selection) {
                            Text("Выбери подключённый MSI").tag("")
                            if !model.selection.isEmpty && model.selectedDisplay == nil {
                                Text("Сохранённый MSI отключён").tag(model.selection)
                            }
                            ForEach(model.displays) { display in
                                Text(display.name + (model.displays.count > 1 ? " · " + display.id.suffix(6) : "")).tag(display.id)
                            }
                        }.disabled(model.busy)
                        HStack(spacing: 8) {
                            Circle().fill(model.selectedDisplay == nil ? Color.orange : Color.green).frame(width: 7, height: 7)
                            Text(model.selectedDisplay == nil ? "Подключи MSI через USB-C." : "MSI подключён")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            if model.busy || model.refreshing { ProgressView().controlSize(.mini) }
                        }
                        HStack(spacing: 10) {
                            Button("В Windows") { model.switchTo(.windows) }.buttonStyle(.borderedProminent)
                            Button("На MacBook") { model.switchTo(.mac) }
                        }.disabled(!model.canSwitch)
                        Picker("Красная клавиша", selection: $model.switchKeyCode) {
                            Text("PageDown").tag(121)
                            Text("PageUp").tag(116)
                        }
                        Toggle("Переключать красной клавишей", isOn: $model.pageDownEnabled)
                        if !model.lastSwitchKey.isEmpty {
                            Text("Получено нажатие: " + model.lastSwitchKey)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text("Переключает после отпускания. Запасное сочетание: ⌃ ⇧ F11.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Text("Клавиатура как на Windows").fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "keyboard").foregroundStyle(.secondary)
                        }
                        Toggle("Ctrl+C / V / X и другие привычные сочетания", isOn: $model.windowsShortcutsEnabled)
                        Text("Копирование, вставка, отмена, поиск, вкладки.\nОбычные сочетания с ⌘ тоже работают.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Toggle("Alt + Shift — менять язык", isOn: $model.languageSwitchEnabled)
                        if !model.lastLanguage.isEmpty {
                            Text("Язык: " + model.lastLanguage).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if !model.accessibility || !model.shortcutsReady {
                            Divider()
                            Label("Клавиши ждут разрешения macOS", systemImage: "lock")
                                .font(.system(size: 12, weight: .medium))
                            Text("Включи MSI DeskSwitch в «Универсальном доступе». Без этого работают только кнопки окна и меню.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Открыть Универсальный доступ…") { model.requestAccessibility() }
                        } else {
                            Label("Клавиатура готова", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.system(size: 12))
                            Toggle("Пауза клавиатурных функций", isOn: $model.paused)
                        }
                    }.padding(8)
                }

                HeadphonesSettings(model: model.headphones)

                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Запускать DeskSwitch при входе", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    if model.loginNeedsApproval {
                        Text("Подтверди автозапуск в настройках macOS.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("Закрой окно — переключатель останется в строке меню.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }

                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }

                HStack {
                    Button(copied ? "Скопировано" : "Копировать диагностику") {
                        model.copyDiagnostics(); copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    }.buttonStyle(.borderless)
                    Spacer()
                    Link("Помощь", destination: URL(string: "https://github.com/w1zardz/msi-deskswitch")!)
                }.font(.system(size: 11))
            }
            .font(.system(size: 13)).padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct HeadphonesSettings: View {
    @ObservedObject var model: HeadphonesController
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Наушники GoXLR", systemImage: "headphones").fontWeight(.semibold)
                Picker("Устройство", selection: $model.serial) {
                    Text("Выбери свой GoXLR").tag("")
                    if !model.serial.isEmpty && model.selected == nil {
                        Text(model.serial + " — отключён").tag(model.serial)
                    }
                    ForEach(model.devices) { device in Text("GoXLR · " + device.id).tag(device.id) }
                }
                Toggle("Ручка клавиатуры управляет наушниками", isOn: $model.enabled)
                    .disabled(model.serial.isEmpty)
                Text("Поворот — громкость Headphones, нажатие — выключить звук и вернуть прежний уровень. Заменяет обычные клавиши громкости этого Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(model.status).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                if !model.lastKey.isEmpty { Text("Получено: " + model.lastKey).font(.system(size: 11)).foregroundStyle(.secondary) }
                HStack {
                    Group {
                        Button("−") { model.enqueue(.step(-5)) }.accessibilityLabel("Тише в наушниках")
                        Button("Вкл./выкл. звук") { model.enqueue(.mute) }
                        Button("+") { model.enqueue(.step(5)) }.accessibilityLabel("Громче в наушниках")
                    }.disabled(!model.captureEnabled)
                    Spacer()
                    Button("Обновить") { Task { await model.refresh() } }.disabled(model.refreshing)
                }
                DisclosureGroup("Подключение к GoXLR Utility") {
                    TextField("Порт", value: $model.port, format: .number.grouping(.never))
                    Text("Подключение только на этом Mac. Обычно порт 14564. Сначала перенеси свои профили в GoXLR Utility.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Link("Инструкция GoXLR", destination: URL(string: "https://github.com/w1zardz/msi-deskswitch/blob/master/Mac/GoXLR.md")!)
                }
            }.padding(8)
        }.task { await model.refresh() }
    }
}
