struct TaskQueue<Element> {
    let maximumConcurrentCount: Int

    private var pending = [Element?]()
    private var pendingHead = 0
    private(set) var runningCount = 0

    init(maximumConcurrentCount: Int) {
        precondition(maximumConcurrentCount > 0)
        self.maximumConcurrentCount = maximumConcurrentCount
    }

    var pendingCount: Int {
        pending.count - pendingHead
    }

    var scheduledCount: Int {
        pendingCount + runningCount
    }

    mutating func enqueue(_ element: Element) {
        pending.append(element)
    }

    mutating func beginNext() -> Element? {
        guard runningCount < maximumConcurrentCount, pendingHead < pending.count else { return nil }
        let element = pending[pendingHead]
        pending[pendingHead] = nil
        pendingHead += 1
        runningCount += 1
        compactPendingStorageIfNeeded()
        return element
    }

    mutating func finish() {
        precondition(runningCount > 0)
        runningCount -= 1
    }

    private mutating func compactPendingStorageIfNeeded() {
        guard pendingHead >= 64, pendingHead * 2 >= pending.count else { return }
        pending.removeFirst(pendingHead)
        pendingHead = 0
    }
}
