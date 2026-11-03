import Foundation
import UIKit
import TelegramVoip

/// Tells the call engine when incoming 1:1 video has nowhere to go: the app is in the background and Picture in
/// Picture is not showing the call. Only acts while Debug Settings ▸ "Calls: drop background video" is on. Main
/// thread. Nothing is signalled to the peer; the decoder keeps running and the next frame after returning to the
/// foreground is shown at once.
final class CallBackgroundVideoGate {
    static let shared = CallBackgroundVideoGate()

    private var isEnabled: Bool = false
    private var isInBackground: Bool = false
    private var isPictureInPictureActive: Bool = false
    private var observers: [NSObjectProtocol] = []
    private var lastApplied: Bool = false

    private init() {
        let center = NotificationCenter.default
        self.observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.isInBackground = true
            self?.apply()
        }))
        self.observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.isInBackground = false
            self?.apply()
        }))
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        self.apply()
    }

    func setPictureInPictureActive(_ isActive: Bool) {
        self.isPictureInPictureActive = isActive
        self.apply()
    }

    private func apply() {
        let drop = CallBackgroundVideoPolicy.shouldDropIncomingVideo(applicationState: self.isInBackground ? .background : .active, isPictureInPictureActive: self.isPictureInPictureActive, isEnabled: self.isEnabled)
        if drop != self.lastApplied {
            self.lastApplied = drop
            OngoingCallContext.setIncomingVideoDropped(drop)
        }
    }
}
