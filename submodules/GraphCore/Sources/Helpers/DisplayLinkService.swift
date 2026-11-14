//
//  DisplayLinkService.swift
//  GraphTest
//
//  Created by Andrei Salavei on 4/7/19.
//  Copyright © 2019 Andrei Salavei. All rights reserved.
//

import Foundation
#if os(macOS)
import Cocoa
#else
import UIKit
#endif
import CoreGraphics

public protocol DisplayLinkListner: AnyObject {
    func update(delta: TimeInterval)
}

// DispatchSource mares refreshes more accurate
#if os(iOS)

private final class DisplayLinkTarget: NSObject {
    weak var service: DisplayLinkService?

    init(service: DisplayLinkService) {
        self.service = service
    }

    @objc func tick(_ link: CADisplayLink) {
        self.service?.fire(frameTime: link.targetTimestamp)
    }
}

class DisplayLinkService {
    let listners = NSHashTable<AnyObject>.weakObjects()
    static let shared = DisplayLinkService()

    private var displayLink: CADisplayLink?
    private var previousTickTime: CFTimeInterval = 0
    private lazy var target = DisplayLinkTarget(service: self)

    private init() {
    }

    public func add(listner: DisplayLinkListner) {
        self.listners.add(listner)
        self.startDisplayLink()
    }

    public func remove(listner: DisplayLinkListner) {
        self.listners.remove(listner)

        if self.listners.count == 0 {
            self.stopDisplayLink()
        }
    }

    private func startDisplayLink() {
        guard self.displayLink == nil else {
            return
        }
        self.previousTickTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self.target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
    }

    private func stopDisplayLink() {
        self.displayLink?.invalidate()
        self.displayLink = nil
    }

    func fire(frameTime: CFTimeInterval) {
        guard self.displayLink != nil else {
            return
        }
        let currentTime = max(frameTime, self.previousTickTime)
        let delta = currentTime - self.previousTickTime
        self.previousTickTime = currentTime

        var hasListners = false
        for listner in self.listners.allObjects {
            if let listner = listner as? DisplayLinkListner {
                listner.update(delta: delta)
                hasListners = true
            }
        }

        if !hasListners {
            self.stopDisplayLink()
        }
    }

    public func fire() {
        self.fire(frameTime: CACurrentMediaTime())
    }
}

#else

class DisplayLinkService {
    let listners = NSHashTable<AnyObject>.weakObjects()
    static let shared = DisplayLinkService()

    public func add(listner: DisplayLinkListner) {
        listners.add(listner)
        startDisplayLink()
    }

    public func remove(listner: DisplayLinkListner) {
        listners.remove(listner)

        if listners.count == 0 {
            stopDisplayLink()
        }
    }

    private init() {
        dispatchSourceTimer.schedule(deadline: .now() + 1.0 / 60, repeating: 1.0 / 60)
        dispatchSourceTimer.setEventHandler {
            DispatchQueue.main.sync {
                self.fire()
            }
        }
    }

    private var dispatchSourceTimer = DispatchSource.makeTimerSource(flags: [], queue: .global(qos: .userInteractive))
    private var dispatchSourceTimerStarted: Bool = false
    private var previousTickTime = 0.0

    private func startDisplayLink() {
        guard !dispatchSourceTimerStarted else { return }
        dispatchSourceTimerStarted = true
        previousTickTime = CACurrentMediaTime()
        dispatchSourceTimer.resume()
    }

    private func stopDisplayLink() {
        guard dispatchSourceTimerStarted else { return }
        dispatchSourceTimerStarted = false
        dispatchSourceTimer.suspend()
    }

    public func fire() {
        let currentTime = CACurrentMediaTime()

        let delta = currentTime - previousTickTime
        previousTickTime = currentTime
        let allListners = listners.allObjects
        var hasListners = false
        for listner in allListners {
            (listner as! DisplayLinkListner).update(delta: delta)
            hasListners = true
        }

        if !hasListners {
            stopDisplayLink()
        }
    }
}

#endif
