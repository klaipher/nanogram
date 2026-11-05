import Foundation

public func deliverOn<T, E>(_ queue: Queue) -> (Signal<T, E>) -> Signal<T, E> {
    return { signal in
        return Signal { subscriber in
            return signal.start(next: { next in
                queue.async {
                    subscriber.putNext(next)
                }
            }, error: { error in
                queue.async {
                    subscriber.putError(error)
                }
            }, completed: {
                queue.async {
                    subscriber.putCompletion()
                }
            })
        }
    }
}

public func deliverOnMainQueue<T, E>(_ signal: Signal<T, E>) -> Signal<T, E> {
    return signal |> deliverOn(Queue.mainQueue())
}

private final class CoalesceOnMainState<T, E> {
    enum Termination {
        case completed
        case failed(E)
    }

    let lock = NSLock()
    var pending: T?
    var termination: Termination?
    var isScheduled = false
    var isDisposed = false
}

/// Delivers on the main queue like `deliverOnMainQueue`, but values that arrive before the main queue gets to
/// deliver are merged: only the last one is delivered, with one main-queue dispatch per run-loop turn however many
/// values came. Use it for state that is redrawn (a status, a count, a title) and not for events: a value that is
/// replaced before the main queue runs is never seen. Completion and error are delivered after the pending value, so
/// the last value is never lost. Delivery is always asynchronous, also from the main queue (that is what merges
/// the values of one turn).
public func coalesceOnMain<T, E>(_ signal: Signal<T, E>) -> Signal<T, E> {
    return Signal { subscriber in
        let state = CoalesceOnMainState<T, E>()
        
        let schedule: () -> Void = {
            // Called with the lock held; returns after scheduling.
            state.isScheduled = true
            Queue.mainQueue().justDispatch {
                state.lock.lock()
                state.isScheduled = false
                if state.isDisposed {
                    state.pending = nil
                    state.lock.unlock()
                    return
                }
                let value = state.pending
                state.pending = nil
                let termination = state.termination
                state.lock.unlock()
                
                if let value = value {
                    subscriber.putNext(value)
                }
                if let termination = termination {
                    switch termination {
                    case .completed:
                        subscriber.putCompletion()
                    case let .failed(error):
                        subscriber.putError(error)
                    }
                }
            }
        }
        
        let disposable = signal.start(next: { next in
            state.lock.lock()
            if state.isDisposed || state.termination != nil {
                state.lock.unlock()
                return
            }
            state.pending = next
            if !state.isScheduled {
                schedule()
            }
            state.lock.unlock()
        }, error: { error in
            state.lock.lock()
            if state.isDisposed || state.termination != nil {
                state.lock.unlock()
                return
            }
            state.termination = .failed(error)
            if !state.isScheduled {
                schedule()
            }
            state.lock.unlock()
        }, completed: {
            state.lock.lock()
            if state.isDisposed || state.termination != nil {
                state.lock.unlock()
                return
            }
            state.termination = .completed
            if !state.isScheduled {
                schedule()
            }
            state.lock.unlock()
        })
        
        return ActionDisposable {
            state.lock.lock()
            state.isDisposed = true
            state.pending = nil
            state.lock.unlock()
            disposable.dispose()
        }
    }
}

public func deliverOn<T, E>(_ threadPool: ThreadPool) -> (Signal<T, E>) -> Signal<T, E> {
    return { signal in
        return Signal { subscriber in
            let queue = threadPool.nextQueue()
            return signal.start(next: { next in
                queue.addTask(ThreadPoolTask { state in
                    if !state.cancelled.with({ $0 }) {
                        subscriber.putNext(next)
                    }
                })
            }, error: { error in
                queue.addTask(ThreadPoolTask { state in
                    if !state.cancelled.with({ $0 }) {
                        subscriber.putError(error)
                    }
                })
            }, completed: {
                queue.addTask(ThreadPoolTask { state in
                    if !state.cancelled.with({ $0 }) {
                        subscriber.putCompletion()
                    }
                })
            })
        }
    }
}

public func runOn<T, E>(_ queue: Queue) -> (Signal<T, E>) -> Signal<T, E> {
    return { signal in
        return Signal { subscriber in
            if queue.isCurrent() {
                return signal.start(next: { next in
                    subscriber.putNext(next)
                }, error: { error in
                    subscriber.putError(error)
                }, completed: {
                    subscriber.putCompletion()
                })
            } else {
                var cancelled = false
                let disposable = MetaDisposable()
                
                disposable.set(ActionDisposable {
                    cancelled = true
                })
                
                queue.async {
                    if cancelled {
                        return
                    }
                    
                    disposable.set(signal.start(next: { next in
                        subscriber.putNext(next)
                    }, error: { error in
                        subscriber.putError(error)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
                }
                
                return disposable
            }
        }
    }
}

public func runOn<T, E>(_ threadPool: ThreadPool) -> (Signal<T, E>) -> Signal<T, E> {
    return { signal in
        return Signal { subscriber in
            let cancelled = false
            let disposable = MetaDisposable()
            
            let task = ThreadPoolTask { state in
                if cancelled || state.cancelled.with({ $0 }) {
                    return
                }
                
                disposable.set(signal.start(next: { next in
                    subscriber.putNext(next)
                }, error: { error in
                    subscriber.putError(error)
                }, completed: {
                    subscriber.putCompletion()
                }))
            }
            
            disposable.set(ActionDisposable {
                task.cancel()
            })
            
            threadPool.addTask(task)
            
            return disposable
        }
    }
}
