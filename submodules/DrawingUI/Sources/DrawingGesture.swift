import Foundation
import UIKit
import Display

class DrawingGestureRecognizer: UIPanGestureRecognizer {
    var shouldBegin: (CGPoint) -> Bool = { _ in return true }
    /// iPad (audit B-7): receives every touch sample of a move, oldest first (`UIEvent.coalescedTouches`).
    var onCoalescedTouches: (([UITouch]) -> Void)?
    
    private var deviceType: DeviceType {
        return UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
    }
    
    /// iPad (audit A-14): with "Only Draw with Apple Pencil" on, a finger does not start a stroke.
    private func acceptsTouch(_ touch: UITouch) -> Bool {
        var prefersPencilOnlyDrawing = false
        if #available(iOS 17.5, *) {
            prefersPencilOnlyDrawing = UIPencilInteraction.prefersPencilOnlyDrawing
        }
        return drawingAcceptsTouch(isPencil: touch.type == .pencil, prefersPencilOnlyDrawing: prefersPencilOnlyDrawing, deviceType: self.deviceType)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.count == 1, let touch = touches.first, self.acceptsTouch(touch), self.shouldBegin(touch.location(in: self.view)) {
            super.touchesBegan(touches, with: event)
            self.state = .began
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.count > 1 {
            self.state = .cancelled
        } else {
            if let onCoalescedTouches = self.onCoalescedTouches, let touch = touches.first {
                onCoalescedTouches(event.coalescedTouches(for: touch) ?? [touch])
            }
            super.touchesMoved(touches, with: event)
        }
    }
}

struct DrawingPoint {
    let location: CGPoint
    let velocity: CGFloat
    
    var x: CGFloat {
        return self.location.x
    }
    
    var y: CGFloat {
        return self.location.y
    }
}

final class DrawingGesturePipeline: NSObject, UIGestureRecognizerDelegate {
    enum DrawingGestureState {
        case began
        case changed
        case ended
        case cancelled
    }
    
    var onDrawing: (DrawingGestureState, DrawingPoint) -> Void = { _, _ in }
    
    var gestureRecognizer: DrawingGestureRecognizer?
    var transform: CGAffineTransform = .identity
        
    var enabled: Bool = true
    
    weak var drawingView: DrawingView?
    
    /// iPad (audit B-7): the stroke takes every coalesced touch sample (`drawingUsesCoalescedTouches`), kept here until
    /// the view accepts a step (`takeSamples`).
    let usesCoalescedTouches: Bool
    private var samples = DrawingSampleBuffer()
    private var lastOriginalLocation: CGPoint?
    
    init(drawingView: DrawingView, gestureView: UIView) {
        self.drawingView = drawingView
        self.usesCoalescedTouches = drawingUsesCoalescedTouches(deviceType: UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone)
        
        super.init()
    
        let gestureRecognizer = DrawingGestureRecognizer(target: self, action: #selector(self.handleGesture(_:)))
        gestureRecognizer.delegate = self
        if self.usesCoalescedTouches {
            gestureRecognizer.onCoalescedTouches = { [weak self] touches in
                guard let self, let drawingView = self.drawingView else {
                    return
                }
                self.samples.append(touches.map { $0.location(in: drawingView) })
            }
        }
        self.gestureRecognizer = gestureRecognizer
        gestureView.addGestureRecognizer(gestureRecognizer)
    }
    
    /// The samples since the last accepted step, ending with the current location, in drawing coordinates; empty
    /// when coalesced touches are not used (the caller then draws the event's point as upstream).
    func takeSamples(velocity: CGFloat) -> [DrawingPoint] {
        guard self.usesCoalescedTouches, let current = self.lastOriginalLocation else {
            return []
        }
        let transform = self.transform
        return self.samples.drain(endingWith: current).map { DrawingPoint(location: $0.applying(transform), velocity: velocity) }
    }
    
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return self.enabled
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is UIPinchGestureRecognizer {
            return true
        }
        return false
    }
    
    var previousPoint: DrawingPoint?
    @objc private func handleGesture(_ gestureRecognizer: DrawingGestureRecognizer) {
        let state: DrawingGestureState
        switch gestureRecognizer.state {
        case .began:
            state = .began
        case .changed:
            state = .changed
        case .ended:
            state = .ended
        case .cancelled:
            state = .cancelled
        case .failed:
            state = .cancelled
        case .possible:
            state = .cancelled
        @unknown default:
            state = .cancelled
        }
        
        let originalLocation = gestureRecognizer.location(in: self.drawingView)
        if state == .began {
            self.samples.reset()
        }
        self.lastOriginalLocation = originalLocation
        let location = originalLocation.applying(self.transform)
        let velocity = gestureRecognizer.velocity(in: self.drawingView).applying(self.transform)
        let velocityValue = velocity.length
        
        let point = DrawingPoint(location: location, velocity: velocityValue)
        self.onDrawing(state, point)
    }
}
