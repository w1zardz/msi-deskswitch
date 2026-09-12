import Foundation
import SwiftUI

enum HeadphonesAction: Equatable {
    case step(Int)
    case mute
}

// NX_KEYTYPE_SOUND_UP / SOUND_DOWN / MUTE. Ownership survives a settings change.
struct VolumeKeyState {
    private var captured = Set<Int>()
    private var inert = Set<Int>()
    mutating func reset() { captured.removeAll(); inert.removeAll() }
    mutating func invalidate() { inert.formUnion(captured) }
    mutating func handle(key: Int, down: Bool, repeated: Bool, enabled: Bool) -> (consume: Bool, action: HeadphonesAction?) {
        guard [0, 1, 7].contains(key) else { return (false, nil) }
        if !down { inert.remove(key); return (captured.remove(key) != nil, nil) }
        if captured.contains(key) {
            return (true, enabled && repeated && key != 7 && !inert.contains(key) ? .step(key == 0 ? 5 : -5) : nil)
        }
        guard enabled, !repeated else { return (false, nil) }
        captured.insert(key)
        return (true, key == 7 ? .mute : .step(key == 0 ? 5 : -5))
    }
}

struct GoXLRDevice: Identifiable, Equatable {
    let id: String
    let volume: Int
}

enum GoXLRError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

protocol GoXLRTransport {
    func devices(port: Int) async throws -> [GoXLRDevice]
    func setVolume(serial: String, value: Int, port: Int) async throws
}

final class GoXLRAPI: NSObject, GoXLRTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func request(_ value: Any, port: Int) async throws -> Data {
        guard (1...65535).contains(port) else { throw GoXLRError.message("Укажи порт GoXLR Utility от 1 до 65535.") }
        let url = URL(string: "http://127.0.0.1:\(port)/api/command")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.url == url,
              data.count <= 2_000_000 else { throw GoXLRError.message("GoXLR Utility вернул неожиданный ответ.") }
        return data
    }

    static func checkError(_ data: Data) throws {
        struct Failure: Decodable { let Error: String }
        if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
            throw GoXLRError.message("GoXLR Utility: " + String(failure.Error.prefix(200)))
        }
    }

    static func parseDevices(_ data: Data) throws -> [GoXLRDevice] {
        try checkError(data)
        struct Envelope: Decodable {
            struct StatusData: Decodable {
                struct Mixer: Decodable {
                    struct Levels: Decodable { let volumes: [String: Int] }
                    let levels: Levels
                }
                let mixers: [String: Mixer]
            }
            let Status: StatusData
        }
        let status = try JSONDecoder().decode(Envelope.self, from: data)
        return try status.Status.mixers.map { serial, mixer in
            guard !serial.isEmpty, serial.count <= 128, let volume = mixer.levels.volumes["Headphones"],
                  (0...255).contains(volume) else { throw GoXLRError.message("Не удалось прочитать громкость Headphones.") }
            return GoXLRDevice(id: serial, volume: volume)
        }.sorted { $0.id < $1.id }
    }

    static func requireOK(_ data: Data) throws {
        try checkError(data)
        guard (try? JSONDecoder().decode(String.self, from: data)) == "Ok" else {
            throw GoXLRError.message("GoXLR Utility не подтвердил изменение громкости.")
        }
    }

    func devices(port: Int) async throws -> [GoXLRDevice] {
        try Self.parseDevices(await request("GetStatus", port: port))
    }

    func setVolume(serial: String, value: Int, port: Int) async throws {
        guard !serial.isEmpty, (0...255).contains(value) else { throw GoXLRError.message("Неверное устройство или громкость.") }
        try Self.requireOK(await request(["Command": [serial, ["SetVolume": ["Headphones", value]]]] as [String: Any], port: port))
    }
}

@MainActor final class HeadphonesController: ObservableObject {
    @Published var serial: String {
        didSet { defaults?.set(serial, forKey: "goxlrSerial"); invalidate() }
    }
    @Published var enabled: Bool {
        didSet { defaults?.set(enabled, forKey: "goxlrEnabled"); invalidate() }
    }
    @Published var port: Int {
        didSet { defaults?.set(port, forKey: "goxlrPort"); invalidate() }
    }
    @Published private(set) var devices: [GoXLRDevice] = []
    @Published private(set) var status = "Запусти GoXLR Utility и выбери устройство."
    @Published private(set) var refreshing = false
    @Published private(set) var lastKey = ""
    // Runtime routing state; preserve the user's saved GoXLR preference on speakers.
    @Published var outputActive = true {
        didSet { if oldValue != outputActive { invalidate() } }
    }
    var onCaptureChanged: (() -> Void)?
    var captureEnabled: Bool { outputActive && enabled && !serial.isEmpty && (1...65535).contains(port) }
    var selected: GoXLRDevice? { devices.first { $0.id == serial } }
    private let api: GoXLRTransport
    private let defaults: UserDefaults?
    private var pending: [HeadphonesAction] = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var activity = 0
    private var restoreVolume: Int?
    private var lastRefresh = Date.distantPast

    init(api: GoXLRTransport = GoXLRAPI(), defaults: UserDefaults? = .standard) {
        self.api = api
        self.defaults = defaults
        serial = defaults?.string(forKey: "goxlrSerial") ?? ""
        enabled = defaults?.object(forKey: "goxlrEnabled") as? Bool ?? false
        port = defaults?.object(forKey: "goxlrPort") as? Int ?? 14564
    }

    func invalidate() {
        generation += 1
        worker?.cancel()
        // The in-flight worker keeps its slot until it has returned; it must never overlap a replacement.
        pending.removeAll()
        restoreVolume = nil
        devices = []
        status = enabled ? "Проверь подключение GoXLR Utility." : "Ручка управляет обычной громкостью компьютера."
        lastRefresh = .distantPast
        onCaptureChanged?()
    }

    func refreshIfNeeded() {
        guard enabled, Date().timeIntervalSince(lastRefresh) >= 3 else { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !refreshing, worker == nil else { return }
        refreshing = true
        lastRefresh = Date()
        let token = generation, activityToken = activity, endpoint = port
        defer { refreshing = false }
        do {
            let found = try await api.devices(port: endpoint)
            guard token == generation, activityToken == activity else { return }
            devices = found
            if let selected {
                if selected.volume != 0 { restoreVolume = nil }
                status = "Наушники: \(Self.percent(selected.volume))%"
            }
            else {
                restoreVolume = nil
                onCaptureChanged?()
                status = serial.isEmpty ? "Выбери свой GoXLR из списка." : "Выбранный GoXLR сейчас отключён."
            }
        } catch {
            guard token == generation, activityToken == activity else { return }
            fail(error)
        }
    }

    func enqueue(_ action: HeadphonesAction) {
        guard captureEnabled else { return }
        activity += 1
        lastKey = action == .mute ? "Выключить / включить звук" : (action == .step(5) ? "Громкость +" : "Громкость −")
        if case .step(let delta) = action, case .step(let previous)? = pending.last,
           (delta > 0) == (previous > 0) {
            pending[pending.count - 1] = .step(max(-255, min(255, previous + delta)))
        } else {
            guard pending.count < 32 else { return }
            pending.append(action)
        }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, !pending.isEmpty, captureEnabled else { return }
        let token = generation, device = serial, endpoint = port
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                self.worker = nil
                // New actions may have arrived for a changed setting while the old read was cancelling.
                self.startWorker()
            }
            do {
                try await Task.sleep(nanoseconds: 35_000_000)
                while token == self.generation, self.captureEnabled, !self.pending.isEmpty {
                    let action = self.pending.removeFirst()
                    let found = try await self.api.devices(port: endpoint)
                    guard token == self.generation, !Task.isCancelled else { return }
                    guard let current = found.first(where: { $0.id == device }) else {
                        throw GoXLRError.message("Выбранный GoXLR отключён. Громкость компьютера не изменена.")
                    }
                    let next: Int
                    switch action {
                    case .step(let delta): next = max(0, min(255, current.volume + delta))
                    case .mute:
                        if current.volume > 0 { next = 0 }
                        else if let previous = self.restoreVolume { next = previous }
                        else {
                            self.devices = found
                            self.status = "Наушники выключены. Поверни ручку, чтобы поднять громкость."
                            continue
                        }
                    }
                    // Cancellation after the fresh read must prevent writes to an old selection.
                    guard token == self.generation, !Task.isCancelled else { return }
                    if next != current.volume {
                        try await self.api.setVolume(serial: device, value: next, port: endpoint)
                    }
                    guard token == self.generation, !Task.isCancelled else { return }
                    if action == .mute, current.volume > 0 { self.restoreVolume = current.volume }
                    else { self.restoreVolume = nil }
                    self.devices = found.map { $0.id == device ? GoXLRDevice(id: device, volume: next) : $0 }
                    self.status = next == 0 ? "Наушники: звук выключен" : "Наушники: \(Self.percent(next))%"
                }
            } catch {
                guard token == self.generation else { return }
                self.pending.removeAll()
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        devices = []
        restoreVolume = nil
        status = (error as? GoXLRError)?.localizedDescription
            ?? "GoXLR Utility недоступен. Проверь запуск программы и подключение GoXLR."
        onCaptureChanged?()
    }

    func waitUntilIdle() async {
        while let task = worker { await task.value }
    }

    static func percent(_ value: Int) -> Int { Int((Double(value) * 100 / 255).rounded()) }
}
