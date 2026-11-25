import XCTest
@testable import CuktechCore

final class NotifyQueueTests: XCTestCase {
    func testPushWakesWaitingReaderImmediately() async {
        let queue = NotifyQueue()
        let start = Date()

        Task.detached {
            try? await Task.sleep(nanoseconds: 30_000_000)
            queue.push([0xAA, 0xBB])
        }

        let got = await queue.read(timeout: 2.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(got, [0xAA, 0xBB])
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testTimeoutReturnsNil() async {
        let queue = NotifyQueue()
        let got = await queue.read(timeout: 0.05)
        XCTAssertNil(got)
    }

    func testZeroBasedIndexMapping() {
        let slots = (1...4).map { PortSlot(index: $0) }
        XCTAssertEqual(slots.map(\.zeroBasedIndex), [0, 1, 2, 3])
    }

    func testAsyncCommandMutexSerializesConcurrentCallers() async {
        let mutex = AsyncCommandMutex()
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var active = 0
            var maxObserved = 0
            func enter() {
                lock.lock()
                active += 1
                maxObserved = max(maxObserved, active)
                lock.unlock()
            }
            func exit() {
                lock.lock()
                active -= 1
                lock.unlock()
            }
        }
        let counter = Counter()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await mutex.acquire()
                    counter.enter()
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    counter.exit()
                    mutex.release()
                }
            }
        }
        XCTAssertEqual(counter.maxObserved, 1)
    }
}
