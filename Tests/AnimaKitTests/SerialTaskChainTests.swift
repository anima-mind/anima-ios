import Foundation
import Testing
@testable import AnimaKit

/// applyWidgetActions solapados (escena + intent + pulso): se encadenan, nunca
/// giran sobre el MainActor esperando un Task ya terminado.
@MainActor @Suite struct SerialTaskChainTests {

    @MainActor final class Recorder {
        var log: [String] = []
        var active = 0
        var maxActive = 0
    }

    @Test(.timeLimit(.minutes(1))) func twoOverlappingDrainsFinishInOrder() async throws {
        try await overlappingDrains(2)
    }

    @Test(.timeLimit(.minutes(1))) func threeOverlappingDrainsFinishInOrder() async throws {
        try await overlappingDrains(3)
    }

    @Test(.timeLimit(.minutes(1))) func aLaterCallWaitsForTheEarlierOne() async {
        let chain = SerialTaskChain()
        let recorder = Recorder()
        let first = Task { @MainActor in
            await chain.run {
                recorder.log.append("a-start")
                try? await Task.sleep(for: .milliseconds(30))
                recorder.log.append("a-end")
            }
        }
        await Task.yield()
        #expect(chain.isBusy)
        await chain.run { recorder.log.append("b") }
        await first.value
        #expect(recorder.log == ["a-start", "a-end", "b"])
        #expect(!chain.isBusy)
        await chain.run { recorder.log.append("c") }
        #expect(recorder.log.last == "c")
    }

    private func overlappingDrains(_ calls: Int) async throws {
        let chain = SerialTaskChain()
        let inbox = WidgetActionInboxTests.inbox()
        for index in 0..<calls * 2 {
            try inbox.enqueue(WidgetAction(kind: .reminderDone(reminderId: "r\(index)"),
                                           createdAt: Date(timeIntervalSince1970: Double(100 + index))))
        }
        let recorder = Recorder()
        let applied = Locked<[String]>([])
        var running: [Task<Void, Never>] = []
        for call in 0..<calls {
            running.append(Task { @MainActor in
                await chain.run {
                    recorder.active += 1
                    recorder.maxActive = max(recorder.maxActive, recorder.active)
                    recorder.log.append("start")
                    await inbox.drain { action in
                        if case .reminderDone(let id) = action.kind { applied.mutate { $0.append(id) } }
                        try? await Task.sleep(for: .milliseconds(5))
                        return .applied
                    }
                    if call == 0 { try? await Task.sleep(for: .milliseconds(10)) }
                    recorder.log.append("end")
                    recorder.active -= 1
                }
            })
        }
        for task in running { await task.value }
        #expect(recorder.maxActive == 1)
        #expect(recorder.log == Array(repeating: ["start", "end"], count: calls).flatMap { $0 })
        #expect(applied.value == (0..<calls * 2).map { "r\($0)" })
        #expect(inbox.pending().isEmpty)
        #expect(!chain.isBusy)
    }
}
