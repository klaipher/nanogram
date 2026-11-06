import Foundation
import UIKit
import AVFoundation
import SwiftSignalKit
import Camera
import CameraMultitaskingPolicy

private extension UIInterfaceOrientation {
    var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeRight:
            return .landscapeRight
        case .landscapeLeft:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
}

final class CameraPreviewView: UIView, CameraSimplePreviewView {
    private let placeholderView = UIImageView()

    init(frame: CGRect, main: Bool, roundVideo: Bool) {
        super.init(frame: frame)

        if roundVideo {
            self.videoPreviewLayer.videoGravity = .resizeAspectFill
            self.placeholderView.contentMode = .scaleAspectFill
        } else {
            self.videoPreviewLayer.videoGravity = main ? .resizeAspectFill : .resizeAspect
            self.placeholderView.contentMode = main ? .scaleAspectFill : .scaleAspectFit
        }
        self.placeholderView.backgroundColor = .black
        self.addSubview(self.placeholderView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override class var layerClass: AnyClass {
        return AVCaptureVideoPreviewLayer.self
    }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = self.layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("Unexpected preview layer type")
        }
        return layer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.placeholderView.frame = self.bounds.insetBy(dx: -1.0, dy: -1.0)
        self.updateOrientation()
    }

    /// Called on main (layout, and after the camera is configured). The orientation is read here, on main; the
    /// connection itself is changed on the session queue (`applyOrientation`): the setter takes the session's
    /// AVFoundation lock, which `startRunning()`/`stopRunning()` hold for as long as they take, and a main-thread
    /// wait on it while the app goes to the background got the app killed by the watchdog (0x8BADF00D).
    func updateOrientation() {
        // iPad (audit A-8): the scene's effective geometry, which follows a resizable window.
        let interfaceOrientation = CameraTabletPolicy.interfaceOrientation(of: self.window?.windowScene)
        let layer = self.videoPreviewLayer
        let orientation = interfaceOrientation.videoOrientation
        if self.orientationTracker.request(orientation) {
            let stopped = self.connectionChangesStopped
            let tracker = self.orientationTracker
            Self.applyOrientation(
                orientation,
                queue: self.connectionQueue,
                isStopped: { stopped.with { $0 } }
            ) { [weak layer] queued in
                guard let connection = layer?.connection, connection.isVideoOrientationSupported else {
                    return
                }
                let latest = tracker.latest ?? queued
                if connection.videoOrientation != latest {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    connection.videoOrientation = latest
                    CATransaction.commit()
                }
                tracker.markApplied(latest)
            }
        }
        layer.removeAllAnimations()
    }

    private let orientationTracker = PreviewOrientationTracker()

    /// Hands an orientation change to `queue` (in order, skipped once `isStopped`), or makes it directly without a queue.
    static func applyOrientation(_ orientation: AVCaptureVideoOrientation, queue: DispatchQueue?, isStopped: @escaping () -> Bool, apply: @escaping (AVCaptureVideoOrientation) -> Void) {
        Self.performConnectionChange(on: queue, isStopped: isStopped) {
            apply(orientation)
        }
    }

    func setSession(_ session: AVCaptureSession, automaticallyConnect: Bool) {
        if automaticallyConnect {
            self.videoPreviewLayer.session = session
        } else {
            self.videoPreviewLayer.setSessionWithNoConnection(session)
        }
    }

    func invalidate() {
        self.videoPreviewLayer.session = nil
    }

    var captureOrientation: AVCaptureVideoOrientation {
        return self.orientationTracker.latest ?? .portrait
    }

    /// The camera's session queue (set by `CameraNeo`; written once, before the view is used from other threads). Enabling or disabling the preview connection is a capture
    /// graph change that AVFoundation serializes with the session's own work, and `startRunning()`/`stopRunning()`
    /// (run on that queue) block for as long as they take. Done on main, a round video paused or resumed while the
    /// session was still stopping or starting could hold the main thread for that long; on the session queue the
    /// change also keeps its order relative to the start or stop queued right after it.
    var connectionQueue: DispatchQueue?

    /// Set on the connection queue when the camera invalidates its session: the layer is about to be detached from
    /// the session on main, and a connection change still queued then would race that detach (see
    /// `CameraSessionInvalidation`).
    private let connectionChangesStopped = Atomic<Bool>(value: false)

    func stopConnectionChanges() {
        let _ = self.connectionChangesStopped.swap(true)
    }

    var isEnabled: Bool = true {
        didSet {
            Self.applyConnectionEnabled(self.isEnabled, layer: self.videoPreviewLayer, queue: self.connectionQueue, isStopped: self.connectionChangesStopped)
        }
    }

    /// Applies `isEnabled` to the preview layer's connection: asynchronously on `queue`, in the order the changes
    /// were made, or directly when there is no queue; not at all once `isStopped`.
    static func applyConnectionEnabled(_ isEnabled: Bool, layer: AVCaptureVideoPreviewLayer, queue: DispatchQueue?, isStopped: Atomic<Bool>) {
        Self.performConnectionChange(on: queue, isStopped: { isStopped.with { $0 } }) { [weak layer] in
            layer?.connection?.isEnabled = isEnabled
        }
    }

    /// `perform(on:)`, skipping `f` if `isStopped` is true by the time it would run.
    static func performConnectionChange(on queue: DispatchQueue?, isStopped: @escaping () -> Bool, _ f: @escaping () -> Void) {
        Self.perform(on: queue) {
            if !isStopped() {
                f()
            }
        }
    }

    static func perform(on queue: DispatchQueue?, _ f: @escaping () -> Void) {
        if let queue {
            queue.async(execute: f)
        } else {
            f()
        }
    }

    @available(iOS 13.0, *)
    var isPreviewing: Signal<Bool, NoError> {
        return Signal { [weak self] subscriber in
            guard let self else {
                return EmptyDisposable
            }
            subscriber.putNext(self.videoPreviewLayer.isPreviewing)
            let observer = self.videoPreviewLayer.observe(\.isPreviewing, options: [.new]) { layer, _ in
                subscriber.putNext(layer.isPreviewing)
            }
            return ActionDisposable {
                observer.invalidate()
            }
        }
        |> distinctUntilChanged
    }

    func removePlaceholder(delay: Double) {
        UIView.animate(withDuration: 0.3, delay: delay) {
            self.placeholderView.alpha = 0.0
        }
    }

    func resetPlaceholder(front: Bool) {
        let fileName = front ? "frontCameraImage.jpg" : "backCameraImage.jpg"
        let fileUrl = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: fileUrl), let image = UIImage(data: data) {
            self.placeholderView.image = image
        } else {
            let imageName = front ? "Camera/SelfiePlaceholder" : "Camera/Placeholder"
            self.placeholderView.image = UIImage(named: imageName)
        }
        self.placeholderView.alpha = 1.0
    }

    func cameraPoint(for location: CGPoint) -> CGPoint {
        return self.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: location)
    }
}
