import Foundation
import UIKit
import QuartzCore
import SwiftSignalKit

// iPad energy decisions from the iPadOS 27 audit (2026-11-03), second batch: B-1 (the shared display link's 120 Hz
// override, behind a Debug Settings switch). Pure functions, as in `TabletSystemRules.swift`, tested by
// `//submodules/Display:TabletSecondBatchTests`. Phones reduce to upstream. B-3 (Power Saving follows the system's
// signals) applies to every device now and lives in `EnergyRules.swift`.

// MARK: - B-1 Shared display link rate on iPad

/// The frame rate range the app's shared display link asks for. `requested` is the fastest of its active links
/// (emoji, stickers, GIF-like animations ask 60 or 30, scrolling-driven ones more). Upstream then forces 30–120 Hz,
/// preferred 120, on every iPad with a 120 Hz screen (`isTablet`), so one visible animated emoji wakes the main thread
/// 120 times a second there, four times the phone's rate. With `capsTabletRate` (Debug Settings, off by default, for
/// the owner's on-device A/B) an iPad follows the phone rule: 120 Hz only when a link asks for more than 60.
/// With `followsUpstreamRate` (Debug Settings "Display link: Telegram's rate", off by default, a scroll-smoothness A/B)
/// every device gets upstream's rule: `.default` for links of 60 fps or less (on a 120 Hz screen the link then runs at up
/// to 120 Hz), 30–120 Hz for faster ones, and an iPad always 30–120 Hz.
public func sharedDisplayLinkFrameRateRange(requested: SharedDisplayLinkDriver.FramesPerSecond, displayMaxFramesPerSecond: Float, isTablet: Bool, capsTabletRate: Bool, followsUpstreamRate: Bool = false) -> CAFrameRateRange {
    if followsUpstreamRate {
        return upstreamSharedDisplayLinkFrameRateRange(requested: requested, displayMaxFramesPerSecond: displayMaxFramesPerSecond, isTablet: isTablet)
    }
    var frameRateRange: CAFrameRateRange = .default
    switch requested {
    case let .fps(fps):
        if fps > 60 {
            if displayMaxFramesPerSecond > 61.0 {
                frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
            }
        } else if fps <= 30 {
            // Every active link wants 30 fps or less (emoji, stickers in Low Power Mode...):
            // ask for 30 instead of waking at the full display rate only to skip frames.
            // Scrolling and Core Animation request their own, higher rates.
            frameRateRange = CAFrameRateRange(minimum: 15.0, maximum: 30.0, preferred: 30.0)
        } else if displayMaxFramesPerSecond > 61.0 {
            // On 120 Hz screens `.default` let the link run at 120 Hz (the app disables the
            // minimum frame duration), waking twice per 60 fps frame.
            frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0)
        }
    case .max:
        if displayMaxFramesPerSecond > 61.0 {
            frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
        }
    }
    if isTablet && !capsTabletRate && displayMaxFramesPerSecond > 61.0 {
        frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
    }
    return frameRateRange
}

/// Upstream Telegram 13.2's rule (`SharedDisplayLinkDriver.update`), unchanged.
func upstreamSharedDisplayLinkFrameRateRange(requested: SharedDisplayLinkDriver.FramesPerSecond, displayMaxFramesPerSecond: Float, isTablet: Bool) -> CAFrameRateRange {
    var frameRateRange: CAFrameRateRange = .default
    switch requested {
    case let .fps(fps):
        if fps > 60 && displayMaxFramesPerSecond > 61.0 {
            frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
        }
    case .max:
        if displayMaxFramesPerSecond > 61.0 {
            frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
        }
    }
    if isTablet && displayMaxFramesPerSecond > 61.0 {
        frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
    }
    return frameRateRange
}

/// Frame pacing of the shared display link over a window of time, for the B-1 A/B: how many callbacks it delivered,
/// their average rate, and how many came late (an interval more than 1.5 times the frame duration the link was
/// running at). One log line per window (`summary`), so a run with the cap on and one with it off can be compared.
public struct DisplayLinkPacingStats: Equatable {
    public private(set) var frames: Int = 0
    public private(set) var lateFrames: Int = 0
    public private(set) var elapsed: Double = 0.0
    public private(set) var longestInterval: Double = 0.0
    private var lastTimestamp: Double?

    public init() {
    }

    /// Records one callback at `timestamp` (the link's `timestamp`) running at `frameDuration` seconds per frame.
    public mutating func record(timestamp: Double, frameDuration: Double) {
        defer {
            self.lastTimestamp = timestamp
        }
        guard let lastTimestamp = self.lastTimestamp else {
            return
        }
        let interval = timestamp - lastTimestamp
        guard interval > 0.0 else {
            return
        }
        self.frames += 1
        self.elapsed += interval
        self.longestInterval = max(self.longestInterval, interval)
        if frameDuration > 0.0 && interval > frameDuration * 1.5 {
            self.lateFrames += 1
        }
    }

    /// Forgets the previous timestamp: the link paused, so the next interval is not a frame.
    public mutating func pause() {
        self.lastTimestamp = nil
    }

    /// A log line once `windowDuration` seconds of frames were recorded, nil before.
    public func summary(windowDuration: Double, capsTabletRate: Bool, preferredFramesPerSecond: Float) -> String? {
        guard self.elapsed >= windowDuration, self.frames > 0 else {
            return nil
        }
        let averageHz = Double(self.frames) / self.elapsed
        let latePercent = Double(self.lateFrames) * 100.0 / Double(self.frames)
        return String(format: "cap=%@ preferred=%.0f frames=%d seconds=%.1f avgHz=%.1f late=%d (%.1f%%) longestMs=%.1f", capsTabletRate ? "on" : "off", preferredFramesPerSecond, self.frames, self.elapsed, averageHz, self.lateFrames, latePercent, self.longestInterval * 1000.0)
    }
}
