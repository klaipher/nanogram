import Foundation
import CoreImage
import UIKit

public enum SharedStickerCIContext {
    public static let context: CIContext = {
        let context = CIContext(options: [.cacheIntermediates: false])
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            context.clearCaches()
        }
        return context
    }()
}
