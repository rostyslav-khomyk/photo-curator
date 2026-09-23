import Foundation

actor CurationScheduler {
    enum Event: Hashable, Sendable {
        case startup
        case userRequested
        case libraryChanged
        case workCompleted
        case policyChanged
        case verificationDue
        case retryDue
    }

    private var pending = Set<Event>()
    private var waiter: CheckedContinuation<Set<Event>, Never>?
    private var deadlines: [Event: Date] = [:]
    private var deadlineTask: Task<Void, Never>?
    private var stopped = false

    func wake(_ event: Event) {
        guard !stopped else { return }
        if deadlines.removeValue(forKey: event) != nil { armDeadline() }
        pending.insert(event)
        resumeWaiterIfNeeded()
    }

    func wake(_ event: Event, at date: Date) {
        guard !stopped else { return }
        if date <= Date() {
            wake(event)
            return
        }
        if let current = deadlines[event], current <= date { return }
        deadlines[event] = date
        armDeadline()
    }

    func next() async -> Set<Event> {
        if !pending.isEmpty { return drain() }
        if stopped { return [] }
        return await withCheckedContinuation { waiter = $0 }
    }

    func stop() {
        stopped = true
        deadlineTask?.cancel()
        deadlineTask = nil
        deadlines.removeAll()
        waiter?.resume(returning: [])
        waiter = nil
    }

    private func fireDeadlines(at date: Date) {
        let due = deadlines.filter { $0.value <= date }.map(\.key)
        for event in due {
            deadlines[event] = nil
            pending.insert(event)
        }
        deadlineTask = nil
        resumeWaiterIfNeeded()
        armDeadline()
    }

    private func armDeadline() {
        deadlineTask?.cancel()
        guard let next = deadlines.values.min() else {
            deadlineTask = nil
            return
        }
        deadlineTask = Task { [weak self] in
            let delay = max(0, next.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fireDeadlines(at: Date())
        }
    }

    private func resumeWaiterIfNeeded() {
        guard let waiter, !pending.isEmpty else { return }
        self.waiter = nil
        waiter.resume(returning: drain())
    }

    private func drain() -> Set<Event> {
        let result = pending
        pending.removeAll(keepingCapacity: true)
        return result
    }
}
