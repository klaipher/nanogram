import XCTest
#if canImport(UniversalMediaPlayer)
@testable import UniversalMediaPlayer
#else
@testable import TelegramMediaPlayer
#endif

/// A frame source's reading thread blocks on a semaphore until MediaBox delivers the bytes. A dispose that arrived
/// before the thread had published its semaphore used to signal nothing, and the thread then waited with nobody left
/// to wake it. These tests drive the wait with a fake data source that delivers only when told to.
final class MediaReadCancellationTests: XCTestCase {
    private final class FakeDataSource {
        private let lock = NSLock()
        private var pending: [DispatchSemaphore] = []
        private(set) var requestCount = 0

        func request() -> DispatchSemaphore {
            let semaphore = DispatchSemaphore(value: 0)
            self.lock.lock()
            self.requestCount += 1
            self.pending.append(semaphore)
            self.lock.unlock()
            return semaphore
        }

        func deliver() {
            self.lock.lock()
            let semaphores = self.pending
            self.pending = []
            self.lock.unlock()
            for semaphore in semaphores {
                semaphore.signal()
            }
        }
    }

    /// Runs `body` on a thread of its own and fails instead of hanging when it does not finish.
    private func runOnReadingThread(_ body: @escaping () -> Void) -> XCTestExpectation {
        let finished = expectation(description: "reading thread finished")
        let thread = Thread {
            body()
            finished.fulfill()
        }
        thread.start()
        return finished
    }

    func testDisposeBeforeTheTaskStartsMeansTheTaskNeverWaits() {
        let lifetime = MediaReadCancellation()
        let scope = MediaReadCancellationScope(lifetime: lifetime)
        let request = MediaReadCancellation()
        request.cancel()
        scope.request = request

        let source = FakeDataSource()
        var waited = true
        let finished = self.runOnReadingThread {
            let semaphore = source.request()
            waited = scope.wait(semaphore)
        }
        self.wait(for: [finished], timeout: 5.0)
        XCTAssertFalse(waited)
        XCTAssertTrue(scope.isCancelled)
    }

    func testSourceDeinitBeforeTheTaskStartsMeansTheTaskNeverWaits() {
        let lifetime = MediaReadCancellation()
        let scope = MediaReadCancellationScope(lifetime: lifetime)
        lifetime.cancel()

        let source = FakeDataSource()
        var waited = true
        let finished = self.runOnReadingThread {
            waited = scope.wait(source.request())
        }
        self.wait(for: [finished], timeout: 5.0)
        XCTAssertFalse(waited)
    }

    func testDisposeWhileWaitingWakesTheReader() {
        let scope = MediaReadCancellationScope(lifetime: MediaReadCancellation())
        let request = MediaReadCancellation()
        scope.request = request

        let source = FakeDataSource()
        let started = DispatchSemaphore(value: 0)
        let finished = self.runOnReadingThread {
            let semaphore = source.request()
            started.signal()
            let _ = scope.wait(semaphore)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5.0), .success)
        Thread.sleep(forTimeInterval: 0.05)
        request.cancel()
        self.wait(for: [finished], timeout: 5.0)
        XCTAssertTrue(scope.isCancelled)
    }

    func testSourceDeinitWhileWaitingWakesTheReader() {
        let lifetime = MediaReadCancellation()
        let scope = MediaReadCancellationScope(lifetime: lifetime)

        let source = FakeDataSource()
        let started = DispatchSemaphore(value: 0)
        let finished = self.runOnReadingThread {
            let semaphore = source.request()
            started.signal()
            scope.wait(semaphore)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5.0), .success)
        Thread.sleep(forTimeInterval: 0.05)
        lifetime.cancel()
        self.wait(for: [finished], timeout: 5.0)
    }

    func testNormalDeliveryStillCompletesTheWaitAndIsNotCancelled() {
        let scope = MediaReadCancellationScope(lifetime: MediaReadCancellation())
        let request = MediaReadCancellation()
        scope.request = request

        let source = FakeDataSource()
        let started = DispatchSemaphore(value: 0)
        var waited = false
        let finished = self.runOnReadingThread {
            let semaphore = source.request()
            started.signal()
            waited = scope.wait(semaphore)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5.0), .success)
        Thread.sleep(forTimeInterval: 0.05)
        source.deliver()
        self.wait(for: [finished], timeout: 5.0)
        XCTAssertTrue(waited)
        XCTAssertFalse(scope.isCancelled)
        XCTAssertEqual(source.requestCount, 1)
    }

    func testCancelAfterTheWaitFinishedDoesNotAffectLaterReads() {
        let scope = MediaReadCancellationScope(lifetime: MediaReadCancellation())
        let request = MediaReadCancellation()
        scope.request = request

        let first = DispatchSemaphore(value: 0)
        first.signal()
        XCTAssertTrue(scope.wait(first))

        scope.request = nil
        request.cancel()

        let second = DispatchSemaphore(value: 0)
        second.signal()
        XCTAssertFalse(scope.isCancelled)
        XCTAssertTrue(scope.wait(second))
    }

    func testCancellingOneRequestDoesNotCancelTheLifetime() {
        let lifetime = MediaReadCancellation()
        let request = MediaReadCancellation()
        request.cancel()
        XCTAssertFalse(lifetime.isCancelled)
        XCTAssertTrue(request.isCancelled)
    }
}
