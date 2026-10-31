import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore

final class ChatMessageThrottledProcessingManager {
    private let queue = Queue.mainQueue()
    
    private let delay: Double
    private let submitInterval: Double?
    
    var process: ((Set<EngineMessageAndThreadId>) -> Void)?
    
    private var timer: SwiftSignalKit.Timer?
    private var processedList: [EngineMessageAndThreadId] = []
    private var processed: [EngineMessageAndThreadId: Double] = [:]
    private var buffer = Set<EngineMessageAndThreadId>()
    
    init(delay: Double = 1.0, submitInterval: Double? = nil) {
        self.delay = delay
        self.submitInterval = submitInterval
    }
    
    func setProcess(process: @escaping (Set<EngineMessageAndThreadId>) -> Void) {
        self.queue.async {
            self.process = process
        }
    }
    
    func add(_ messageIds: [EngineMessageAndThreadId]) {
        self.queue.async { [weak self] in
            guard let self else {
                return
            }

            let timestamp = CFAbsoluteTimeGetCurrent()
            
            for id in messageIds {
                if let processedTimestamp = self.processed[id] {
                    if let submitInterval = self.submitInterval, (submitInterval.isZero || (timestamp - processedTimestamp) >= submitInterval) {
                        self.processed[id] = timestamp
                        self.processedList.append(id)
                        self.buffer.insert(id)
                    }
                } else {
                    self.processed[id] = timestamp
                    self.processedList.append(id)
                    self.buffer.insert(id)
                }
            }
            
            if self.processedList.count > 1000 {
                for i in 0 ..< 200 {
                    self.processed.removeValue(forKey: self.processedList[i])
                }
                self.processedList.removeSubrange(0 ..< 200)
            }
            
            if self.timer == nil {
                var completionImpl: (() -> Void)?
                let timer = SwiftSignalKit.Timer(timeout: self.delay, repeat: false, completion: {
                    completionImpl?()
                }, queue: self.queue)
                completionImpl = { [weak self, weak timer] in
                    if let strongSelf = self {
                        if let timer = timer, strongSelf.timer === timer {
                            strongSelf.timer = nil
                        }
                        let buffer = strongSelf.buffer
                        strongSelf.buffer.removeAll()
                        strongSelf.process?(buffer)
                    }
                }
                self.timer = timer
                timer.start()
            }
        }
    }
}


final class ChatMessageVisibleThrottledProcessingManager {
    private let queue = Queue.mainQueue()
    
    private let interval: Double
    
    private var currentIds = Set<EngineMessageAndThreadId>()
    
    private var isPaused = false
    
    var process: ((Set<EngineMessageAndThreadId>) -> Void)?
    
    // Runs only while there are ids to refresh and the chat is shown, instead of waking every interval for the node's lifetime.
    private var timer: SwiftSignalKit.Timer?
    
    init(interval: Double = 5.0) {
        self.interval = interval
    }
    
    deinit {
        self.timer?.invalidate()
    }
    
    func setProcess(process: @escaping (Set<EngineMessageAndThreadId>) -> Void) {
        self.queue.async {
            self.process = process
        }
    }
    
    func update(_ ids: Set<EngineMessageAndThreadId>) {
        self.queue.async {
            if self.currentIds != ids {
                self.currentIds = ids
                if !self.currentIds.isEmpty {
                    self.process?(self.currentIds)
                }
                self.updateTimer()
            }
        }
    }
    
    func setPaused(_ isPaused: Bool) {
        self.queue.async {
            if self.isPaused != isPaused {
                self.isPaused = isPaused
                if !isPaused && !self.currentIds.isEmpty {
                    self.process?(self.currentIds)
                }
                self.updateTimer()
            }
        }
    }
    
    private func updateTimer() {
        if self.currentIds.isEmpty || self.isPaused {
            self.timer?.invalidate()
            self.timer = nil
        } else if self.timer == nil {
            let timer = SwiftSignalKit.Timer(timeout: self.interval, repeat: true, completion: { [weak self] in
                guard let self, !self.currentIds.isEmpty else {
                    return
                }
                self.process?(self.currentIds)
            }, queue: self.queue)
            self.timer = timer
            timer.start()
        }
    }
}
