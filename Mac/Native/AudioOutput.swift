import Foundation
import SwiftUI
import CoreAudio

struct MacAudioOutput: Identifiable, Equatable {
    enum Kind: Equatable { case speakers, goxlr }
    let id: String
    let name: String
    let kind: Kind

    static func kind(uid: String, transport: UInt32, hasOutput: Bool, alive: Bool) -> Kind? {
        guard hasOutput, alive else { return nil }
        if transport == kAudioDeviceTransportTypeBuiltIn { return .speakers }
        if transport == kAudioDeviceTransportTypeAggregate,
           uid.hasPrefix("GoXLR-Utility::Aggregate::"), uid.hasSuffix("::System") { return .goxlr }
        return nil
    }
}

struct MacAudioSnapshot {
    let outputs: [MacAudioOutput]
    let outputUID: String
    let systemOutputUID: String
    let outputName: String
}

enum MacAudioChange { case devices, output }

@MainActor protocol MacAudioBackend: AnyObject {
    func snapshot() throws -> MacAudioSnapshot
    func setOutput(_ uid: String) throws
    func setSystemOutput(_ uid: String) throws
    func observe(_ callback: @escaping (MacAudioChange) -> Void) throws
    func stop()
}

private struct MacAudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor final class AudioOutputController: ObservableObject {
    @Published private(set) var outputs: [MacAudioOutput] = []
    @Published private(set) var actualOutputUID = ""
    @Published private(set) var preferredUID: String
    @Published private(set) var status = "Проверяю выход звука…"
    @Published private(set) var error: String?
    @Published private(set) var actualOutputName = "Выход звука недоступен"
    var onOutputWillChange: (() -> Void)?
    var onOutputChanged: (() -> Void)?
    var usesGoXLR: Bool { outputs.contains { $0.id == actualOutputUID && $0.kind == .goxlr } }
    private let backend: MacAudioBackend
    private let defaults: UserDefaults?
    private let settleNanoseconds: UInt64
    private var recovery: Task<Void, Never>?
    private var stopped = false
    private var observationValid = false
    private var settledUID = ""
    private var settledOutputs = Set<String>()
    private var pendingTopology = false
    private let reconnectGrace: TimeInterval
    private var reconnectDeadline = Date.distantPast

    init(backend: MacAudioBackend? = nil, defaults: UserDefaults? = .standard,
         settleNanoseconds: UInt64 = 250_000_000, reconnectGrace: TimeInterval = 2) {
        self.backend = backend ?? CoreAudioBackend()
        self.defaults = defaults
        self.settleNanoseconds = settleNanoseconds
        self.reconnectGrace = reconnectGrace
        preferredUID = defaults?.string(forKey: "audioOutputUID") ?? ""
        refresh()
        restorePreferred()
        rememberObservedState()
        do { try self.backend.observe { [weak self] change in self?.changed(change) } }
        catch { self.error = error.localizedDescription }
    }

    func select(_ uid: String) {
        recovery?.cancel()
        recovery = nil
        pendingTopology = false
        reconnectDeadline = .distantPast
        apply(uid, remember: true)
    }

    func refresh() {
        do { accept(try backend.snapshot()) }
        catch {
            observationValid = false
            let hadOutput = !actualOutputUID.isEmpty
            actualOutputUID = ""
            actualOutputName = "Выход звука недоступен"
            outputs = []
            self.error = error.localizedDescription
            status = "Не удалось проверить выход звука."
            if hadOutput { onOutputChanged?() }
        }
    }

    func stop() {
        stopped = true
        recovery?.cancel()
        recovery = nil
        backend.stop()
    }

    private func changed(_ change: MacAudioChange) {
        guard !stopped else { return }
        refresh()
        guard observationValid else { return }
        // CoreAudio may report a default-output change before its device-list notification.
        // Compare snapshots, then coalesce both notifications before classifying a user choice.
        pendingTopology = pendingTopology || Set(outputs.map(\.id)) != settledOutputs
        recovery?.cancel()
        let delay = settleNanoseconds
        recovery = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.recovery = nil
            self.settleChanges()
        }
    }

    private func settleChanges() {
        refresh()
        guard observationValid else { return }
        let topologyChanged = pendingTopology || Set(outputs.map(\.id)) != settledOutputs
        pendingTopology = false
        if topologyChanged { reconnectDeadline = Date().addingTimeInterval(reconnectGrace) }
        if topologyChanged || Date() < reconnectDeadline {
            // Keep the explicit route through the short USB/aggregate reconnection sequence.
            restorePreferred()
        } else if actualOutputUID != settledUID {
            // A choice made in macOS becomes the new preference; unrelated future hotplug
            // must not undo it. Other devices (AirPods/HDMI) release DeskSwitch's preference.
            let supported = outputs.filter { $0.id == actualOutputUID }.count == 1
            preferredUID = supported ? actualOutputUID : ""
            if supported { defaults?.set(preferredUID, forKey: "audioOutputUID") }
            else { defaults?.removeObject(forKey: "audioOutputUID") }
        }
        rememberObservedState()
    }

    private func rememberObservedState() {
        guard observationValid else { return }
        settledUID = actualOutputUID
        settledOutputs = Set(outputs.map(\.id))
    }

    private func restorePreferred() {
        guard !preferredUID.isEmpty, outputs.contains(where: { $0.id == preferredUID }) else { return }
        apply(preferredUID, remember: false)
    }

    private func accept(_ snapshot: MacAudioSnapshot) {
        let previousGoXLR = usesGoXLR
        let changed = actualOutputUID != snapshot.outputUID
        observationValid = true
        outputs = snapshot.outputs
        actualOutputUID = snapshot.outputUID
        actualOutputName = snapshot.outputName
        if !preferredUID.isEmpty && !outputs.contains(where: { $0.id == preferredUID }) {
            status = "Сейчас: \(snapshot.outputName). Сохранённый выход вернётся после подключения."
        } else { status = "Сейчас: \(snapshot.outputName)" }
        if changed || previousGoXLR != usesGoXLR { onOutputChanged?() }
    }

    private func apply(_ uid: String, remember: Bool) {
        defer { rememberObservedState(); onOutputChanged?() }
        do {
            let previous = try backend.snapshot()
            accept(previous)
            guard !uid.isEmpty, previous.outputs.filter({ $0.id == uid }).count == 1 else {
                throw MacAudioError(message: "Этот выход сейчас недоступен. Выбери подключённое устройство.")
            }
            var confirmed = previous
            let changingOutput = previous.outputUID != uid
            let changingSystem = previous.systemOutputUID != uid
            if changingOutput || changingSystem {
                onOutputWillChange?()
                do {
                    if changingOutput { try backend.setOutput(uid) }
                    if changingSystem { try backend.setSystemOutput(uid) }
                    let current = try backend.snapshot()
                    guard current.outputUID == uid, current.systemOutputUID == uid else {
                        throw MacAudioError(message: "macOS не подтвердила переключение обоих выходов звука.")
                    }
                    confirmed = current
                } catch {
                    // The setter can apply before reporting an error; attempt both original values.
                    var rollbackFailed = false
                    if changingSystem { do { try backend.setSystemOutput(previous.systemOutputUID) } catch { rollbackFailed = true } }
                    if changingOutput { do { try backend.setOutput(previous.outputUID) } catch { rollbackFailed = true } }
                    if let restored = try? backend.snapshot() {
                        accept(restored)
                        rollbackFailed = rollbackFailed || restored.outputUID != previous.outputUID
                            || restored.systemOutputUID != previous.systemOutputUID
                    } else {
                        observationValid = false
                        actualOutputUID = ""
                        actualOutputName = "Выход звука недоступен"
                        outputs = []
                        rollbackFailed = true
                    }
                    if rollbackFailed {
                        throw MacAudioError(message: "Переключение не завершено. Проверь выход в настройках звука macOS.")
                    }
                    throw error
                }
            }
            if remember {
                preferredUID = uid
                defaults?.set(uid, forKey: "audioOutputUID")
            }
            self.error = nil
            accept(confirmed)
        } catch {
            self.error = error.localizedDescription
            status = error.localizedDescription
        }
    }
}

@MainActor private final class CoreAudioBackend: MacAudioBackend {
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private func address(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func values(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
        var property = address(selector, scope: scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size % 4 == 0, size <= 1_000_000 else {
            throw MacAudioError(message: "macOS не вернула список аудиоустройств.")
        }
        if size == 0 { return [] }
        var result = [UInt32](repeating: 0, count: Int(size) / 4)
        let status = result.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &property, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { throw MacAudioError(message: "Аудиоустройство отключилось во время проверки.") }
        return result
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector), value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr, let value else {
            throw MacAudioError(message: "Не удалось прочитать имя аудиоустройства.")
        }
        return value.takeRetainedValue() as String
    }

    private func hasOutput(_ id: AudioObjectID) -> Bool {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size, size < 1_000_000 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, memory) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    func snapshot() throws -> MacAudioSnapshot {
        let ids = try values(system, kAudioHardwarePropertyDevices)
        var outputs: [MacAudioOutput] = []
        for id in ids {
            guard let uid = try? string(id, kAudioDevicePropertyDeviceUID),
                  let name = try? string(id, kAudioObjectPropertyName),
                  let transport = try? values(id, kAudioDevicePropertyTransportType).first,
                  let alive = try? values(id, kAudioDevicePropertyDeviceIsAlive).first,
                  let kind = MacAudioOutput.kind(uid: uid, transport: transport, hasOutput: hasOutput(id), alive: alive == 1) else { continue }
            outputs.append(MacAudioOutput(id: uid, name: name, kind: kind))
        }
        outputs = outputs.map { output in
            let count = outputs.filter { $0.kind == output.kind }.count
            let label = output.kind == .speakers ? "Динамики MacBook" : "Наушники GoXLR"
            let name = count == 1 ? label : "\(output.name) · \(output.id.replacingOccurrences(of: "::System", with: "").suffix(24))"
            return MacAudioOutput(id: output.id, name: name, kind: output.kind)
        }
        let output = try values(system, kAudioHardwarePropertyDefaultOutputDevice).first ?? kAudioObjectUnknown
        let effects = try values(system, kAudioHardwarePropertyDefaultSystemOutputDevice).first ?? kAudioObjectUnknown
        return MacAudioSnapshot(outputs: outputs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            outputUID: try string(output, kAudioDevicePropertyDeviceUID),
            systemOutputUID: try string(effects, kAudioDevicePropertyDeviceUID),
            outputName: try outputs.first { $0.id == (try? string(output, kAudioDevicePropertyDeviceUID)) }?.name
                ?? (try string(output, kAudioObjectPropertyName)))
    }

    private func set(_ uid: String, selector: AudioObjectPropertySelector) throws {
        let matching = try values(system, kAudioHardwarePropertyDevices).filter {
            (try? string($0, kAudioDevicePropertyDeviceUID)) == uid && hasOutput($0)
        }
        guard matching.count == 1, var id = matching.first else {
            throw MacAudioError(message: "Выбранное аудиоустройство отключено или его нельзя определить однозначно.")
        }
        var property = address(selector)
        guard AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr,
              try values(system, selector).first == id else {
            throw MacAudioError(message: "macOS не подтвердила изменение выхода звука.")
        }
    }

    func setOutput(_ uid: String) throws { try set(uid, selector: kAudioHardwarePropertyDefaultOutputDevice) }
    func setSystemOutput(_ uid: String) throws { try set(uid, selector: kAudioHardwarePropertyDefaultSystemOutputDevice) }

    func observe(_ callback: @escaping (MacAudioChange) -> Void) throws {
        stop()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var property = address(selector)
            let change: MacAudioChange = selector == kAudioHardwarePropertyDevices ? .devices : .output
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in callback(change) }
            }
            guard AudioObjectAddPropertyListenerBlock(system, &property, .main, listener) == noErr else {
                stop()
                throw MacAudioError(message: "Не удалось включить автоматическое восстановление выхода звука.")
            }
            listeners.append((property, listener))
        }
    }

    func stop() {
        for (var property, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(system, &property, .main, listener)
        }
        listeners.removeAll()
    }
}
