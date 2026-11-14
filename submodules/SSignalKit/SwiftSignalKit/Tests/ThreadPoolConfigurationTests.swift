import XCTest
@testable import SwiftSignalKit

final class ThreadPoolConfigurationTests: XCTestCase {
    func testPriorityMapsToQualityOfService() {
        XCTAssertEqual(ThreadPool.qualityOfService(forThreadPriority: 0.2), .utility)
        XCTAssertEqual(ThreadPool.qualityOfService(forThreadPriority: 0.5), .default)
        XCTAssertEqual(ThreadPool.qualityOfService(forThreadPriority: 1.0), .userInitiated)
    }

    func testLegacyConfigurationKeepsThePriority() {
        XCTAssertEqual(ThreadPool.threadConfiguration(forThreadPriority: 0.2, usesQualityOfService: false), .priority(0.2))
    }

    func testQualityOfServiceConfigurationUsesTheMapping() {
        XCTAssertEqual(ThreadPool.threadConfiguration(forThreadPriority: 0.2, usesQualityOfService: true), .qualityOfService(.utility))
        XCTAssertEqual(ThreadPool.threadConfiguration(forThreadPriority: 0.5, usesQualityOfService: true), .qualityOfService(.default))
    }

    func testPoolStillRunsTasks() {
        let pool = ThreadPool(threadCount: 2, threadPriority: 0.2)
        let done = expectation(description: "task ran")
        pool.addTask(ThreadPoolTask { _ in
            done.fulfill()
        })
        wait(for: [done], timeout: 5.0)
    }
}
