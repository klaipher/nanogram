import UIKit

struct RebalanceRowBudget {
    let maxSpeculativeRows: Int
    private(set) var speculativeRows = 0
    private(set) var deferred = false

    init(maxSpeculativeRows: Int) {
        self.maxSpeculativeRows = maxSpeculativeRows
    }

    mutating func admit(edgeIsInsideViewport: Bool) -> Bool {
        if edgeIsInsideViewport {
            return true
        }
        guard speculativeRows < maxSpeculativeRows else {
            deferred = true
            return false
        }
        speculativeRows += 1
        return true
    }
}

struct ScrollTickSignature: Equatable {
    var offset: CGFloat
    var solveOffset: CGFloat
    var windowRevision: Int
    var containerOriginY: CGFloat
    var logicalSize: CGSize
    var insets: UIEdgeInsets
}
