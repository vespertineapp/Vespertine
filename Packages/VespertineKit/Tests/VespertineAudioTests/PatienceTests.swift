//
// Vespertine: the tests' own wait (`Patience.until`). Awaited in an async test, it must leave Swift's shared threads to the
// work it waits for. A wait that slept on its thread held one of them: on a three-core runner the handoff test's wait for
// the engine's task held a thread the task needed, until the wait's ten minutes ran out, and every other test stood still.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Testing
@testable import VespertineAudio

@Suite("The tests' wait")
struct PatienceTests {
    @Test("Waits awaited in async tests, one for each of Swift's shared threads, still let the task they wait for run")
    func waitsLeaveTheSharedThreadsFree() async {
        let done = Locked(false)
        // As many waits as the shared pool has threads (its width is the processor count): a wait that sleeps on its
        // thread would leave none for the task below until one gave up.
        let waits = ProcessInfo.processInfo.activeProcessorCount
        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<waits {
                group.addTask { await Patience.until(giveUpAfter: 120) { done.withLock { $0 } } }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                done.withLock { $0 = true }
                return true
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        #expect(results.count == waits + 1)
        #expect(results.allSatisfy { $0 }, "a wait gave up: the task it waited for never had a thread")
    }
}
