import Testing
@testable import XDecodeApp

@Suite("Task queue")
struct TaskQueueTests {
    @Test("App queue is configured for two concurrent tasks")
    @MainActor
    func appQueueConcurrency() {
        #expect(AppModel.maximumConcurrentDecodeTaskCount == 2)
    }

    @Test("Pending task count is not limited")
    func acceptsUnboundedPendingTasks() {
        var queue = TaskQueue<Int>(maximumConcurrentCount: 2)
        for value in 0..<1_000 {
            queue.enqueue(value)
        }

        #expect(queue.scheduledCount == 1_000)
        #expect(queue.pendingCount == 1_000)
    }

    @Test("Only the configured number of tasks can run")
    func enforcesConcurrency() {
        var queue = TaskQueue<Int>(maximumConcurrentCount: 2)
        queue.enqueue(1)
        queue.enqueue(2)
        queue.enqueue(3)

        let first = queue.beginNext()
        let second = queue.beginNext()
        let blocked = queue.beginNext()
        #expect(first == 1)
        #expect(second == 2)
        #expect(blocked == nil)
        queue.finish()
        let third = queue.beginNext()
        #expect(third == 3)
    }

    @Test("FIFO order survives internal storage compaction")
    func preservesOrderAcrossCompaction() {
        var queue = TaskQueue<Int>(maximumConcurrentCount: 1)
        for value in 0..<200 {
            queue.enqueue(value)
        }

        for expected in 0..<200 {
            #expect(queue.beginNext() == expected)
            queue.finish()
        }
        #expect(queue.pendingCount == 0)
        #expect(queue.scheduledCount == 0)
    }
}
