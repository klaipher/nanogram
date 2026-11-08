import Foundation
import UIKit
import QuartzCore
import SwiftSignalKit

// iPad energy decisions from the iPadOS 27 audit (2026-11-03), second batch: B-1 (the shared display link's 120 Hz
// override, removed). Pure functions, as in `TabletSystemRules.swift`, tested by
// `//submodules/Display:TabletSecondBatchTests`. Phones reduce to upstream. B-3 (Power Saving follows the system's
// signals) applies to every device now and lives in `EnergyRules.swift`.

// MARK: - B-1 Shared display link rate on iPad

/// The frame rate range the app's shared display link asks for. `requested` is the fastest of its active links
/// (emoji, stickers, GIF-like animations ask 60 or 30, scrolling-driven ones more). Upstream then forces 30–120 Hz,
/// preferred 120, on every iPad with a 120 Hz screen (`isTablet`), so one visible animated emoji wakes the main thread
/// 120 times a second there, four times the phone's rate. Here an iPad follows the phone rule: 120 Hz only when a link
/// asks for more than 60 (Debug Settings switch on by default from 2026-11-07, removed 2026-11-08). `isTablet` is kept
/// for callers and tests; the rule no longer depends on it.
public func sharedDisplayLinkFrameRateRange(requested: SharedDisplayLinkDriver.FramesPerSecond, displayMaxFramesPerSecond: Float, isTablet: Bool) -> CAFrameRateRange {
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
    return frameRateRange
}

