import Foundation
import CoreAudio

private struct AudioOutputTestError: LocalizedError {
    let errorDescription: String? = "Test audio failure"
}

@MainActor private final class FakeAudioBackend: MacAudioBackend {
    var outputs: [MacAudioOutput]
    var outputUID: String
    var systemUID: String
    var inputUID = "User microphone"
    var volume = 0.27
    var writes: [(String, String)] = []
    var failSystemOnce = false
    var ignoreSystemOnce = false
    var applyOutputThenFailOnce = false
    var failSnapshot = false
    var failReadsAfterNextWrite = false
    var beforeWrite: (() -> Void)?
    private var callback: ((MacAudioChange) -> Void)?

    init(_ outputs: [MacAudioOutput], output: String, system: String? = nil) {
        self.outputs = outputs
        outputUID = output
        systemUID = system ?? output
    }
    func snapshot() throws -> MacAudioSnapshot {
        if failSnapshot { throw AudioOutputTestError() }
        return MacAudioSnapshot(outputs: outputs, outputUID: outputUID, systemOutputUID: systemUID,
            outputName: outputs.first { $0.id == outputUID }?.name ?? "Other audio device")
    }
    func setOutput(_ uid: String) throws {
        beforeWrite?()
        writes.append(("output", uid))
        outputUID = uid
        if failReadsAfterNextWrite { failReadsAfterNextWrite = false; failSnapshot = true }
        if applyOutputThenFailOnce { applyOutputThenFailOnce = false; throw AudioOutputTestError() }
    }
    func setSystemOutput(_ uid: String) throws {
        beforeWrite?()
        writes.append(("system", uid))
        if failSystemOnce { failSystemOnce = false; throw AudioOutputTestError() }
        if ignoreSystemOnce { ignoreSystemOnce = false; return }
        systemUID = uid
    }
    func observe(_ callback: @escaping (MacAudioChange) -> Void) throws { self.callback = callback }
    func emit(_ change: MacAudioChange) { callback?(change) }
    func stop() { callback = nil }
}

@MainActor func testAudioOutput() async throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try CoreTests.expect(condition(), "Audio output: " + message)
    }
    let speaker = MacAudioOutput(id: "builtin-output", name: "Динамики MacBook", kind: .speakers)
    let goxlr = MacAudioOutput(id: "GoXLR-Utility::Aggregate::USB-A::System", name: "Наушники GoXLR", kind: .goxlr)
    let otherGoXLR = MacAudioOutput(id: "GoXLR-Utility::Aggregate::USB-B::System", name: "Other GoXLR", kind: .goxlr)
    let suite = "DeskSwitch-AudioOutput-Tests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    try check(MacAudioOutput.kind(uid: speaker.id, transport: kAudioDeviceTransportTypeBuiltIn,
        hasOutput: true, alive: true) == .speakers, "built-in output is eligible")
    try check(MacAudioOutput.kind(uid: goxlr.id, transport: kAudioDeviceTransportTypeAggregate,
        hasOutput: true, alive: true) == .goxlr, "only Utility System aggregate is eligible")
    for uid in ["GoXLR", "fake::System", "GoXLR-Utility::Aggregate::USB-A::Music", "GoXLR-Utility::Aggregate::USB-A::ChatMic"] {
        try check(MacAudioOutput.kind(uid: uid, transport: kAudioDeviceTransportTypeAggregate,
            hasOutput: true, alive: true) == nil, "reject misleading or wrong-channel UID \(uid)")
    }
    try check(MacAudioOutput.kind(uid: goxlr.id, transport: kAudioDeviceTransportTypeUSB,
        hasOutput: true, alive: true) == nil, "raw USB device is not a System aggregate")
    try check(MacAudioOutput.kind(uid: speaker.id, transport: kAudioDeviceTransportTypeBuiltIn,
        hasOutput: false, alive: true) == nil, "built-in microphone is excluded")
    try check(MacAudioOutput.kind(uid: goxlr.id, transport: kAudioDeviceTransportTypeAggregate,
        hasOutput: true, alive: false) == nil, "disconnected output is excluded")

    let backend = FakeAudioBackend([speaker, goxlr, otherGoXLR], output: speaker.id)
    let controller = AudioOutputController(backend: backend, defaults: defaults, settleNanoseconds: 1, reconnectGrace: 0)
    defer { controller.stop() }
    try check(backend.writes.isEmpty && controller.preferredUID.isEmpty, "new users keep existing audio; no hidden first device")
    try check(!controller.usesGoXLR && controller.actualOutputUID == speaker.id, "capture uses actual output")
    controller.select("missing")
    try check(backend.writes.isEmpty && controller.preferredUID.isEmpty && controller.error != nil,
        "unknown selection fails without changing or saving anything")
    controller.select("")
    try check(backend.writes.isEmpty, "empty selection cannot fall back")

    var captureActive = true
    var changedCallbacks = 0
    var wroteBeforeInvalidation = false
    controller.onOutputWillChange = { captureActive = false }
    controller.onOutputChanged = { captureActive = controller.usesGoXLR; changedCallbacks += 1 }
    backend.beforeWrite = { if captureActive { wroteBeforeInvalidation = true } }
    controller.select(goxlr.id)
    try check(backend.outputUID == goxlr.id && backend.systemUID == goxlr.id, "select changes program and effects outputs")
    try check(!wroteBeforeInvalidation && captureActive && changedCallbacks > 0, "capture invalidates before writes and restores after success")
    try check(controller.preferredUID == goxlr.id && defaults.string(forKey: "audioOutputUID") == goxlr.id,
        "only successful exact UID is remembered")
    try check(backend.inputUID == "User microphone" && backend.volume == 0.27, "microphone and volume are untouched")
    let writesAfterSelection = backend.writes.count
    let callbacksBeforeNoOp = changedCallbacks
    controller.select(goxlr.id)
    try check(backend.writes.count == writesAfterSelection && changedCallbacks > callbacksBeforeNoOp,
        "same-output selection avoids writes but reports completion")

    backend.failSystemOnce = true
    controller.select(speaker.id)
    try check(backend.outputUID == goxlr.id && backend.systemUID == goxlr.id, "second-write failure rolls back first output")
    try check(controller.preferredUID == goxlr.id && defaults.string(forKey: "audioOutputUID") == goxlr.id,
        "failed route cannot replace saved preference")
    try check(captureActive && controller.error != nil, "capture follows restored route after failure")
    backend.applyOutputThenFailOnce = true
    controller.select(speaker.id)
    try check(backend.outputUID == goxlr.id && captureActive, "setter that applies before throwing is also rolled back")
    backend.ignoreSystemOnce = true
    controller.select(speaker.id)
    try check(backend.outputUID == goxlr.id && backend.systemUID == goxlr.id && controller.error != nil,
        "unconfirmed system-effects write rolls back")

    controller.select(speaker.id)
    try check(!captureActive && !controller.usesGoXLR && backend.systemUID == speaker.id,
        "speakers selection releases knob to macOS")
    controller.select(goxlr.id)
    backend.beforeWrite = nil
    backend.writes.removeAll()
    backend.outputUID = speaker.id
    backend.systemUID = speaker.id
    backend.emit(.output)
    try await Task.sleep(nanoseconds: 5_000_000)
    try check(backend.writes.isEmpty && !controller.usesGoXLR && controller.preferredUID == speaker.id,
        "manual macOS speaker choice becomes current preference without writes")
    backend.emit(.devices)
    try await Task.sleep(nanoseconds: 5_000_000)
    try check(backend.writes.isEmpty && backend.outputUID == speaker.id && controller.preferredUID == speaker.id,
        "unrelated device notification cannot undo manual macOS speaker choice")
    controller.select(goxlr.id)
    backend.writes.removeAll()
    backend.outputUID = speaker.id
    backend.systemUID = speaker.id

    backend.outputs = [speaker]
    backend.emit(.output)
    backend.emit(.devices)
    try await Task.sleep(nanoseconds: 5_000_000)
    try check(backend.writes.isEmpty && controller.preferredUID == goxlr.id,
        "output-first USB removal keeps choice waiting without mistaking fallback for manual choice")
    backend.outputs = [speaker, otherGoXLR]
    backend.emit(.devices)
    try await Task.sleep(nanoseconds: 5_000_000)
    try check(backend.writes.isEmpty && backend.outputUID == speaker.id, "different GoXLR cannot replace disconnected selected UID")
    backend.outputs = [speaker, otherGoXLR, goxlr]
    backend.emit(.devices)
    try await Task.sleep(nanoseconds: 5_000_000)
    try check(backend.outputUID == goxlr.id && backend.systemUID == goxlr.id && controller.usesGoXLR,
        "return of explicitly remembered UID restores both defaults")

    controller.select(speaker.id)
    backend.outputs = [speaker]
    backend.emit(.devices)
    try await Task.sleep(nanoseconds: 5_000_000)
    backend.writes.removeAll()
    backend.outputs = [speaker, goxlr]
    backend.outputUID = goxlr.id
    backend.systemUID = goxlr.id
    backend.emit(.output)
    backend.emit(.devices)
    try await Task.sleep(nanoseconds: 5_000_000)
    try check(backend.outputUID == speaker.id && !controller.usesGoXLR,
        "remembered speaker mode survives GoXLR reattachment")

    backend.outputs = [speaker, goxlr, goxlr]
    backend.writes.removeAll()
    controller.select(goxlr.id)
    try check(backend.writes.isEmpty && controller.preferredUID == speaker.id,
        "ambiguous duplicate UID fails instead of taking first")
    backend.outputs = [speaker, goxlr]
    backend.failSnapshot = true
    controller.refresh()
    try check(controller.actualOutputUID.isEmpty && !controller.usesGoXLR,
        "failed output read cannot leave stale GoXLR capture active")
    backend.failSnapshot = false
    controller.refresh()

    backend.failReadsAfterNextWrite = true
    controller.select(goxlr.id)
    try check(controller.actualOutputUID.isEmpty && !controller.usesGoXLR && controller.error != nil,
        "unreadable rollback clears stale capture instead of claiming an output")
    try check(controller.actualOutputName == "Выход звука недоступен" && controller.preferredUID == speaker.id,
        "unverified route clears label and preserves previous preference")
    backend.failSnapshot = false

    controller.select(goxlr.id)
    let classificationCallbacks = changedCallbacks
    backend.outputs = [speaker]
    controller.refresh()
    try check(controller.actualOutputUID == goxlr.id && !controller.usesGoXLR
        && changedCallbacks > classificationCallbacks, "same UID losing GoXLR classification notifies capture")
    let missingClassificationCallbacks = changedCallbacks
    backend.outputs = [speaker, goxlr]
    controller.refresh()
    try check(controller.usesGoXLR && changedCallbacks > missingClassificationCallbacks,
        "same UID regaining GoXLR classification notifies capture")
    backend.outputUID = "AirPods UID"
    backend.systemUID = "AirPods UID"
    backend.writes.removeAll()
    backend.emit(.output)
    try await Task.sleep(nanoseconds: 5_000_000)
    try check(controller.preferredUID.isEmpty && defaults.string(forKey: "audioOutputUID") == nil
        && backend.writes.isEmpty, "manual unsupported output releases saved routing preference")
    controller.select(speaker.id)

    let graceBackend = FakeAudioBackend([speaker], output: speaker.id)
    let graceController = AudioOutputController(backend: graceBackend, defaults: nil,
        settleNanoseconds: 1, reconnectGrace: 0.2)
    defer { graceController.stop() }
    graceController.select(speaker.id)
    graceBackend.outputs = [speaker, goxlr]
    graceBackend.emit(.devices)
    try await Task.sleep(nanoseconds: 5_000_000)
    graceBackend.outputUID = goxlr.id
    graceBackend.systemUID = goxlr.id
    graceBackend.emit(.output)
    try await Task.sleep(nanoseconds: 5_000_000)
    try check(graceBackend.outputUID == speaker.id && graceController.preferredUID == speaker.id,
        "brief reconnect grace also catches late automatic default selection")

    // Recreate with saved preference; tests use only a private defaults suite and fake audio.
    let startupBackend = FakeAudioBackend([speaker, goxlr], output: goxlr.id)
    let startupController = AudioOutputController(backend: startupBackend, defaults: defaults, settleNanoseconds: 1, reconnectGrace: 0)
    defer { startupController.stop() }
    try check(startupBackend.outputUID == speaker.id && startupBackend.systemUID == speaker.id,
        "startup restores a present saved output")
    defaults.set("missing-saved-UID", forKey: "audioOutputUID")
    let missingBackend = FakeAudioBackend([speaker, goxlr], output: speaker.id)
    let missingController = AudioOutputController(backend: missingBackend, defaults: defaults, settleNanoseconds: 1, reconnectGrace: 0)
    defer { missingController.stop() }
    try check(missingBackend.writes.isEmpty && missingController.preferredUID == "missing-saved-UID",
        "missing saved UID remains explicit and never becomes another output")
}
