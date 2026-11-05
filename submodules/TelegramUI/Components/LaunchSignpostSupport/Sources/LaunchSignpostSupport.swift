import Foundation
import UIKit
import SwiftSignalKit

public enum LaunchSignpostPolicy {
    // A launch in the background (a push, a VoIP push, a background fetch) never shows a first frame. The MetricKit
    // extended launch measurement finishes when all its tasks finish (Apple, MXMetricManager.extendLaunchMeasurement),
    // so every phase is ended at once and the measurement does not stay open until the user opens the app.
    public static func phasesToEnd(atLaunchInBackground isBackground: Bool) -> [LaunchPhase] {
        return isBackground ? LaunchPhase.allCases : []
    }
}

public enum SignpostCommit {
    // Runs `completion` on the main thread after the next Core Animation commit that follows the current run-loop
    // turn, so a signpost that ends here includes the first frame of the work it measures. The explicit transaction
    // opens in the next turn: the commit of the turn that did the work has then happened. Without animations in the
    // transaction its completion block runs at its commit.
    public static func afterNextCommit(_ completion: @escaping () -> Void) {
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock(completion)
            CATransaction.commit()
        }
    }
}
