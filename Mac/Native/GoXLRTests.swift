import Foundation

@MainActor private final class FakeGoXLR: GoXLRTransport {
    var values = ["A": 100, "B": 200]
    var writes: [(String, Int, Int)] = []
    var failReads = false
    var failWrites = false
    var applyBeforeError = false
    var beforeRead: (() -> Void)?
    var beforeWrite: (() -> Void)?

    func devices(port: Int) async throws -> [GoXLRDevice] {
        let callback = beforeRead
        beforeRead = nil
        callback?()
        if failReads { throw GoXLRError.message("offline") }
        return values.map { GoXLRDevice(id: $0.key, volume: $0.value) }
    }
    func setVolume(serial: String, value: Int, port: Int) async throws {
        let callback = beforeWrite
        beforeWrite = nil
        callback?()
        writes.append((serial, value, port))
        if applyBeforeError { values[serial] = value }
        if failWrites { throw GoXLRError.message("unconfirmed write") }
        values[serial] = value
    }
}

extension CoreTests {
    @MainActor static func headphones() async throws {
        func data(_ text: String) -> Data { Data(text.utf8) }
        let fixture = data(#"{"Status":{"mixers":{"A":{"hardware":{"device_type":"Full"},"levels":{"volumes":{"Headphones":128}}},"B":{"levels":{"volumes":{"Headphones":255}}}}}}"#)
        let parsed = try GoXLRAPI.parseDevices(fixture)
        try expect(parsed == [GoXLRDevice(id: "A", volume: 128), GoXLRDevice(id: "B", volume: 255)], "Parse upstream Status wrapper, serials and raw levels")
        let empty = try GoXLRAPI.parseDevices(data(#"{"Status":{"mixers":{}}}"#))
        try expect(empty.isEmpty, "No device is not a default device")
        for value in ["-1", "256", "1.2", "true", "null", #""128""#] {
            try rejects("Invalid Headphones level \(value) must fail") {
                _ = try GoXLRAPI.parseDevices(data("{\"Status\":{\"mixers\":{\"A\":{\"levels\":{\"volumes\":{\"Headphones\":\(value)}}}}}}"))
            }
        }
        for text in [#"{"Error":"disconnected"}"#, #"{"mixers":{}}"#, #"{"Status":{"mixers":{"A":{"levels":{"volumes":{}}}}}}"#, "broken"] {
            try rejects("Malformed status must not supply a volume") { _ = try GoXLRAPI.parseDevices(data(text)) }
        }
        try GoXLRAPI.requireOK(data(#""Ok""#))
        for text in [#"{"Error":"disconnected"}"#, #"{"Ok":true}"#, #""OK""#, "null", ""] {
            try rejects("Only confirmed Ok is a successful write") { try GoXLRAPI.requireOK(data(text)) }
        }
        var keys = VolumeKeyState()
        try expect(!keys.handle(key: 0, down: true, repeated: false, enabled: false).consume, "Disabled volume is untouched")
        try expect(keys.handle(key: 0, down: true, repeated: false, enabled: true).action == .step(5), "VolumeUp produces one small step")
        try expect(keys.handle(key: 0, down: true, repeated: false, enabled: true).action == nil, "Duplicate down is not another tick")
        try expect(keys.handle(key: 0, down: true, repeated: true, enabled: true).action == .step(5), "Held volume may repeat")
        try expect(keys.handle(key: 0, down: false, repeated: false, enabled: false).consume, "Consume owned up after disabling")
        try expect(!keys.handle(key: 1, down: true, repeated: true, enabled: true).consume, "Do not capture a key already held before enabling")
        try expect(keys.handle(key: 7, down: true, repeated: false, enabled: true).action == .mute, "Mute on down")
        try expect(keys.handle(key: 7, down: true, repeated: true, enabled: true).action == nil, "Holding mute never toggles repeatedly")
        try expect(keys.handle(key: 7, down: false, repeated: false, enabled: true).action == nil, "Mute up does not toggle")
        try expect(!keys.handle(key: 16, down: true, repeated: false, enabled: true).consume, "Play/Pause remains untouched")
        _ = keys.handle(key: 0, down: true, repeated: false, enabled: true)
        keys.invalidate()
        let staleRepeat = keys.handle(key: 0, down: true, repeated: true, enabled: true)
        try expect(staleRepeat.consume && staleRepeat.action == nil, "An already held key becomes inert across device/config changes")
        try expect(keys.handle(key: 0, down: false, repeated: false, enabled: true).consume, "Keep ownership until the inert key is released")
        try expect(keys.handle(key: 0, down: true, repeated: false, enabled: true).action == .step(5), "A new press is allowed after release")

        let api = FakeGoXLR()
        let control = HeadphonesController(api: api, defaults: nil)
        control.enabled = true
        control.enqueue(.step(5))
        await control.waitUntilIdle()
        try expect(api.writes.isEmpty && !control.captureEnabled, "An explicit serial is required even with one or more devices")
        control.serial = "A"
        for _ in 0..<10 { control.enqueue(.step(5)) }
        await control.waitUntilIdle()
        try expect(api.writes.count == 1 && api.values["A"] == 150 && api.values["B"] == 200, "Batch same-direction ticks without modifying another mixer")
        api.writes.removeAll(); api.values["A"] = 250
        control.enqueue(.step(5)); control.enqueue(.step(5)); control.enqueue(.step(-5))
        await control.waitUntilIdle()
        try expect(api.writes.map { $0.1 } == [255, 250], "Clamp in gesture order, never cancel opposite directions across a boundary")
        api.writes.removeAll(); api.values["A"] = 3
        control.enqueue(.step(-5))
        await control.waitUntilIdle()
        try expect(api.values["A"] == 0, "Clamp below zero")
        control.enqueue(.mute)
        await control.waitUntilIdle()
        try expect(api.writes.count == 1, "Mute at an unknown zero never invents a recovery volume")

        api.writes.removeAll(); api.values["A"] = 137
        control.enqueue(.mute); control.enqueue(.mute)
        await control.waitUntilIdle()
        try expect(api.writes.map { $0.1 } == [0, 137], "Mute restores the exact confirmed raw level")
        api.writes.removeAll(); control.enqueue(.mute); control.enqueue(.step(5)); control.enqueue(.mute)
        await control.waitUntilIdle()
        try expect(api.writes.map { $0.1 } == [0, 5, 0], "Turning from mute increases from silence; preserve mute ordering")
        control.invalidate(); api.writes.removeAll()
        control.enqueue(.mute)
        await control.waitUntilIdle()
        try expect(api.writes.isEmpty, "USB/session invalidation forgets the old profile's recovery volume")

        api.values["A"] = 128; api.failWrites = true; api.applyBeforeError = true
        control.enqueue(.mute); control.enqueue(.mute); control.enqueue(.step(5))
        await control.waitUntilIdle()
        try expect(api.writes.count == 1 && api.values["A"] == 0, "Ambiguous write failure discards queued operations and is not retried")
        api.failWrites = false; api.applyBeforeError = false; api.writes.removeAll()
        control.enqueue(.mute)
        await control.waitUntilIdle()
        try expect(api.writes.isEmpty, "An unconfirmed mute cannot later restore a potentially unsafe level")

        api.failReads = true
        control.enqueue(.step(5)); control.enqueue(.mute)
        await control.waitUntilIdle()
        try expect(api.writes.isEmpty && control.devices.isEmpty, "No status means no writes and no deferred replay")
        api.failReads = false; control.serial = "MISSING"
        control.enqueue(.step(5)); await control.waitUntilIdle()
        try expect(api.writes.isEmpty, "A disconnected selected serial never falls back to A or B")

        control.serial = "A"; api.values["A"] = 100
        api.beforeRead = { control.serial = "B" }
        control.enqueue(.step(5)); await control.waitUntilIdle()
        try expect(api.writes.isEmpty, "Selection change during a read prevents the stale write")
        control.serial = "A"
        api.beforeRead = { control.enabled = false }
        control.enqueue(.step(5)); await control.waitUntilIdle()
        try expect(api.writes.isEmpty, "Disable during a read cancels the gesture")
        control.enabled = true
        api.beforeRead = { control.port = 14565 }
        control.enqueue(.step(5)); await control.waitUntilIdle()
        try expect(api.writes.isEmpty, "Port changes cancel old-server writes")
        control.port = 0
        try expect(!control.captureEnabled, "Invalid ports do not capture volume keys")
        control.port = 14565
        control.enqueue(.step(5)); await control.waitUntilIdle()
        try expect(api.writes.last?.2 == 14565, "Use the user's explicit port")
        control.enabled = false
    }
}
