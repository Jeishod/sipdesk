import Testing
import SIPRuntime
import SIPCore

@Suite(.serialized)
struct SIPWorkerTests {
    @Test func startsAndStopsOnItsOwnThreadWithOrderedEvents() async throws {
        for _ in 0..<2 {
            let worker = SIPWorker(headless: true)
            var events = worker.signals.makeAsyncIterator()
            let first = await events.next()
            if case .ready(let version) = first { #expect(version.hasPrefix("2.17")) }
            else { Issue.record("Expected a ready event, got \(String(describing: first))") }
            let devices = try await worker.devices(refresh: false)
            #expect(devices.allSatisfy { $0.id >= 0 })
            await withCheckedContinuation { continuation in
                worker.shutdown { continuation.resume() }
            }
            let last = await events.next()
            if case .stopped = last {} else { Issue.record("Expected stopped after ready") }
            #expect(await events.next() == nil)
        }
    }

    @Test func rejectsCommandsAfterShutdown() async {
        let worker = SIPWorker(headless: true)
        var events = worker.signals.makeAsyncIterator()
        _ = await events.next()
        await withCheckedContinuation { continuation in
            worker.shutdown { continuation.resume() }
        }
        await #expect(throws: SIPFailure.self) { _ = try await worker.devices() }
    }

    @Test func cancellationPreventsQueuedDial() async {
        let worker = SIPWorker(headless: true)
        var events = worker.signals.makeAsyncIterator()
        _ = await events.next()
        let intent = DialIntent()
        intent.cancel()
        await #expect(throws: CancellationError.self) {
            try await worker.placeCall(uri: "sip:1002@127.0.0.1:9", audio: AudioPreferences(), intent: intent)
        }
        await withCheckedContinuation { continuation in
            worker.shutdown { continuation.resume() }
        }
    }
}

