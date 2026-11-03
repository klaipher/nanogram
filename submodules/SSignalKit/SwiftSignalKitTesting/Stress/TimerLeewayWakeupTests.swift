import XCTest
import Foundation
import Darwin
#if SSK_LEGACY
import SwiftSignalKitLegacy
private typealias LeewayTimer = SwiftSignalKitLegacy.Timer
#else
import SwiftSignalKit2
private typealias LeewayTimer = SwiftSignalKit2.Timer
#endif

private func processWakeups() -> UInt64 {
    var info = task_power_info()
    var count = mach_msg_type_number_t(MemoryLayout<task_power_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else {
        return 0
    }
    return info.task_interrupt_wakeups + info.task_platform_idle_wakeups
}

final class TimerLeewayWakeupTests: XCTestCase {
    private func measureWakeupsPerSecond(leeway: TimerLeeway, duration: Double) -> Double {
        let queue = Queue(name: "leeway.wakeups")
        let fired = Atomic<Int>(value: 0)
        var timers: [LeewayTimer] = []
        let started = expectation(description: "started")
        for i in 0 ..< 40 {
            let period = 1.0 + Double(i % 40) * 0.1
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.025) {
                let timer = LeewayTimer(timeout: period, repeat: true, completion: {
                    let _ = fired.modify { $0 + 1 }
                }, queue: queue, leeway: leeway)
                queue.async {
                    timers.append(timer)
                    timer.start()
                    if timers.count == 40 {
                        started.fulfill()
                    }
                }
            }
        }
        wait(for: [started], timeout: 10.0)
        let before = processWakeups()
        let measured = expectation(description: "measured")
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
            measured.fulfill()
        }
        wait(for: [measured], timeout: duration + 10.0)
        let wakeups = processWakeups() - before
        queue.sync {
            for timer in timers {
                timer.invalidate()
            }
        }
        XCTAssertGreaterThan(fired.with { $0 }, 40)
        return Double(wakeups) / duration
    }

    func testAutomaticLeewayCoalescesStaggeredRepeatingTimers() {
        let precise = self.measureWakeupsPerSecond(leeway: .precise, duration: 10.0)
        let automatic = self.measureWakeupsPerSecond(leeway: .automatic, duration: 10.0)
        print("TimerLeewayWakeupTests: 40 staggered 1.0-4.9 s repeating timers: precise \(String(format: "%.2f", precise)) wake-ups/s, automatic \(String(format: "%.2f", automatic)) wake-ups/s")
        #if !SSK_LEGACY
        XCTAssertLessThan(automatic, precise)
        #endif
    }
}
