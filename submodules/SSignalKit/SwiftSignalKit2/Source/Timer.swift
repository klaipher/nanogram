import Foundation

/// How much the system may delay a `Timer` so it can fire together with other wake-ups.
public enum TimerLeeway {
    /// `min(10% of the timeout, 1 s)` for timeouts of 1 s or longer, none below that. Use it for
    /// timers whose exact firing time nobody sees (polling, retries, expirations, background work).
    case automatic
    /// No leeway. Use it for timers the user can see: count-downs, recording and playback timers,
    /// animation loops, gestures, typing indicators and anything that hides or shows UI.
    case precise
}

public final class Timer {
    private var lock = os_unfair_lock()
    private var timer: DispatchSourceTimer?
    private let timeout: Double
    private let `repeat`: Bool
    private let completion: (Timer) -> Void
    private let queue: Queue
    private let leeway: TimerLeeway
    
    public init(timeout: Double, `repeat`: Bool, completion: @escaping () -> Void, queue: Queue, leeway: TimerLeeway = .automatic) {
        self.timeout = timeout
        self.`repeat` = `repeat`
        self.completion = { _ in
            completion()
        }
        self.queue = queue
        self.leeway = leeway
    }
    
    public init(timeout: Double, `repeat`: Bool, completion: @escaping (Timer) -> Void, queue: Queue, leeway: TimerLeeway = .automatic) {
        self.timeout = timeout
        self.`repeat` = `repeat`
        self.completion = completion
        self.queue = queue
        self.leeway = leeway
    }
    
    static func leewaySeconds(timeout: Double, leeway: TimerLeeway) -> Double {
        switch leeway {
        case .precise:
            return 0.0
        case .automatic:
            if timeout >= 1.0 {
                return min(timeout * 0.1, 1.0)
            } else {
                return 0.0
            }
        }
    }
    
    var leewaySeconds: Double {
        return Timer.leewaySeconds(timeout: self.timeout, leeway: self.leeway)
    }
    
    deinit {
        self.invalidate()
    }
    
    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: self.queue.queue)
        timer.setEventHandler(handler: { [weak self] in
            if let strongSelf = self {
                strongSelf.completion(strongSelf)
                if !strongSelf.`repeat` {
                    strongSelf.invalidate()
                }
            }
        })
        
        os_unfair_lock_lock(&self.lock)
        var previousTimer = self.timer
        self.timer = timer
        os_unfair_lock_unlock(&self.lock)
        
        if let previousTimerValue = previousTimer {
            previousTimer = nil
            previousTimerValue.cancel()
        }
        
        let leeway: DispatchTimeInterval = .nanoseconds(Int(self.leewaySeconds * 1_000_000_000.0))
        if self.`repeat` {
            let time: DispatchTime = DispatchTime.now() + self.timeout
            timer.schedule(deadline: time, repeating: self.timeout, leeway: leeway)
        } else {
            let time: DispatchTime = DispatchTime.now() + self.timeout
            timer.schedule(deadline: time, leeway: leeway)
        }
        
        timer.resume()
    }
    
    public func invalidate() {
        os_unfair_lock_lock(&self.lock)
        let timer = self.timer
        self.timer = nil
        os_unfair_lock_unlock(&self.lock)
        
        timer?.cancel()
    }
}
