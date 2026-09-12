import Foundation

@main struct GoXLRHTTPTests {
    static func reject(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { return }
        throw GoXLRError.message("Expected an HTTP/protocol failure")
    }
    static func main() async {
        do {
            guard Bundle.main.bundleIdentifier == "ru.w1zardz.msi-deskswitch.http-tests",
                  CommandLine.arguments.count == 2, let port = Int(CommandLine.arguments[1]) else {
                throw GoXLRError.message("The transport test must run from its application bundle")
            }
            let api = GoXLRAPI()
            let before = try await api.devices(port: port)
            guard before == [GoXLRDevice(id: "TEST", volume: 128)] else { throw GoXLRError.message("Status mismatch") }
            try await api.setVolume(serial: "TEST", value: 133, port: port)
            let after = try await api.devices(port: port)
            guard after == [GoXLRDevice(id: "TEST", volume: 133)] else { throw GoXLRError.message("Write was not reflected") }
            for serial in ["ERROR", "HTTP500", "MALFORMED", "REDIRECT", "TIMEOUT"] {
                try await reject { try await api.setVolume(serial: serial, value: 5, port: port) }
            }
            try await reject { try await api.setVolume(serial: "TEST", value: 256, port: port) }
            try await reject { _ = try await api.devices(port: 0) }
            print("PASS: bundled loopback HTTP, payloads, ACK/error, redirect rejection and timeout")
        } catch {
            fputs("FAIL: bundled HTTP: \(error)\n", stderr)
            exit(1)
        }
    }
}
