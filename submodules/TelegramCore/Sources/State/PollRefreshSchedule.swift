import Foundation
import SwiftSignalKit

func pollRefreshRemainingTime(startDate: Int32, deadlineTimeout: Int32?, deadlineDate: Int32?, now: Int32) -> Int32? {
    let deadline: Int32
    if let deadlineDate {
        deadline = deadlineDate
    } else if let deadlineTimeout {
        deadline = startDate + deadlineTimeout
    } else {
        return nil
    }
    return deadline - now
}

func pollRefreshSignal(fetch: Signal<Never, NoError>, reachedDeadline: Bool, burstInterval: Double, regularInterval: Double) -> Signal<Never, NoError> {
    let regular: Signal<Never, NoError> = (fetch |> then(.complete() |> delay(regularInterval, queue: Queue.concurrentDefaultQueue()))) |> restart
    if !reachedDeadline {
        return regular
    }
    let fetchOnce: Signal<Never, NoError> = fetch |> then(.complete() |> delay(burstInterval, queue: Queue.concurrentDefaultQueue()))
    var burst: Signal<Never, NoError> = .complete()
    for _ in 0 ..< 10 {
        burst = burst |> then(fetchOnce)
    }
    return burst |> then(regular)
}
