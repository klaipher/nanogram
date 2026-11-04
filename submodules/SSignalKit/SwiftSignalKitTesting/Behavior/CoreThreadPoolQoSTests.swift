import XCTest
import Foundation
#if SSK_LEGACY
@testable import SwiftSignalKitLegacy
#else
@testable import SwiftSignalKit2
#endif

final class CoreThreadPoolQoSTests: XCTestCase {
    private func qosInsideTask(_ pool: ThreadPool) -> qos_class_t {
        let done = self.expectation(description: "task")
        var result = QOS_CLASS_UNSPECIFIED
        pool.nextQueue().addTask(ThreadPoolTask { _ in
            result = qos_class_self()
            done.fulfill()
        })
        self.wait(for: [done], timeout: 5.0)
        return result
    }

    func testWorkersRunWithTheRequestedQualityOfService() {
        XCTAssertEqual(self.qosInsideTask(ThreadPool(threadCount: 1, qos: .userInitiated)), QOS_CLASS_USER_INITIATED)
        XCTAssertEqual(self.qosInsideTask(ThreadPool(threadCount: 1, qos: .utility)), QOS_CLASS_UTILITY)
    }

    func testLegacyPrioritiesMapToQualityOfService() {
        XCTAssertEqual(self.qosInsideTask(ThreadPool(threadCount: 1, threadPriority: 1.0)), QOS_CLASS_USER_INITIATED)
        XCTAssertEqual(self.qosInsideTask(ThreadPool(threadCount: 1, threadPriority: 0.5)), QOS_CLASS_DEFAULT)
        XCTAssertEqual(self.qosInsideTask(ThreadPool(threadCount: 1, threadPriority: 0.2)), QOS_CLASS_UTILITY)
        XCTAssertEqual(ThreadPool.qualityOfService(forThreadPriority: 0.9), .userInitiated)
        XCTAssertEqual(ThreadPool.qualityOfService(forThreadPriority: 0.4), .default)
        XCTAssertEqual(ThreadPool.qualityOfService(forThreadPriority: 0.1), .utility)
    }

    func testEachTaskWakesOneParkedWorker() {
        let pool = ThreadPool(threadCount: 4, qos: .utility)
        Thread.sleep(forTimeInterval: 0.2)
        let before = pool.conditionWakeups
        let tasks = 40
        for _ in 0 ..< tasks {
            let done = DispatchSemaphore(value: 0)
            pool.nextQueue().addTask(ThreadPoolTask { _ in
                done.signal()
            })
            done.wait()
            Thread.sleep(forTimeInterval: 0.005)
        }
        let wakeups = pool.conditionWakeups - before
        print("ThreadPool wake-ups \(wakeups) for \(tasks) tasks on 4 workers")
        XCTAssertLessThanOrEqual(wakeups, tasks + 4, "wake-ups \(wakeups) for \(tasks) tasks on 4 workers")
    }

    func testParallelQueuesStillUseEveryWorker() {
        let pool = ThreadPool(threadCount: 4, qos: .utility)
        let lock = NSLock()
        var running = 0
        var maximum = 0
        let group = DispatchGroup()
        for _ in 0 ..< 4 {
            let queue = pool.nextQueue()
            for _ in 0 ..< 3 {
                group.enter()
                queue.addTask(ThreadPoolTask { _ in
                    lock.lock()
                    running += 1
                    maximum = max(maximum, running)
                    lock.unlock()
                    Thread.sleep(forTimeInterval: 0.05)
                    lock.lock()
                    running -= 1
                    lock.unlock()
                    group.leave()
                })
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(maximum, 4)
    }
}
