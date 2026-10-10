/// Holds async stubs until the test explicitly releases them, including after cancellation. Every waiter is released.
actor TestGate {
    private var waiters: [CheckedContinuation<Void,Never>] = []
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true; let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}
