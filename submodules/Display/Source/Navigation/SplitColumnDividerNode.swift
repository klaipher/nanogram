import Foundation
import UIKit
import AsyncDisplayKit

/// The draggable divider between the chat list and the chat (iPad split view). Nanogram-only.
///
/// A transparent strip over the 1px separator line (`NavigationSplitContainer.separator`), 12pt into the list
/// and 4pt into the chat, so it stays clear of the list's trailing buttons and the chat's close button. Dragging
/// it resizes the list live (one navigation layout per pan event, `SplitColumnWidth.dragged`), with a selection
/// tick when it lands on a snap point; releasing writes the width for the window's shape
/// (`SplitColumnWidthStore`), a double tap forgets it. A grabber appears while the strip is touched, dragged or
/// under the pointer, which also turns into a ↔ arrow. VoiceOver sees an adjustable "Chat list width" element.
///
/// Every width decision is in `SplitColumnWidth.swift`; this file only turns gestures into store writes and
/// asks the navigation controller that owns the split for a layout.
final class SplitColumnDividerNode: ASDisplayNode {
    static let listSideHitWidth: CGFloat = 12.0
    static let chatSideHitWidth: CGFloat = 4.0

    override init() {
        super.init()

        self.setViewBlock({
            return SplitColumnDividerView(frame: CGRect())
        })
    }

    private var dividerView: SplitColumnDividerView {
        return self.view as! SplitColumnDividerView
    }

    /// The strip's frame in the split container for a list `masterWidth` wide.
    static func frame(containerSize: CGSize, masterWidth: CGFloat) -> CGRect {
        return CGRect(x: masterWidth - SplitColumnDividerNode.listSideHitWidth, y: 0.0, width: SplitColumnDividerNode.listSideHitWidth + SplitColumnDividerNode.chatSideHitWidth, height: containerSize.height)
    }

    func update(containerSize: CGSize, masterWidth: CGFloat, isEnabled: Bool, grabberColor: UIColor, transition: ContainedViewLayoutTransition) {
        transition.updateFrame(node: self, frame: SplitColumnDividerNode.frame(containerSize: containerSize, masterWidth: masterWidth))
        self.dividerView.update(containerSize: containerSize, masterWidth: masterWidth, isEnabled: isEnabled, grabberColor: grabberColor, transition: transition)
    }

    func updateGrabberColor(_ color: UIColor) {
        if self.isNodeLoaded {
            self.dividerView.updateGrabberColor(color)
        }
    }
}

final class SplitColumnDividerView: UIView, UIPointerInteractionDelegate {
    private static let grabberSize = CGSize(width: 5.0, height: 44.0)
    /// A layer that renders nothing receives no real touches on iOS 26+ (CLAUDE.md, "iOS 26/27 windows and touch
    /// delivery"), so the strip carries transparent contents.
    private static let transparentContents: CGImage? = generateImage(CGSize(width: 1.0, height: 1.0), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
    })?.cgImage

    private let store = SplitColumnWidthStore.shared
    private let grabber: UIView
    private let hapticFeedback = HapticFeedback()

    private var containerSize = CGSize()
    private var masterWidth: CGFloat = 0.0
    private var isDividerEnabled = false

    private var dragStartWidth: CGFloat?
    /// The shape the drag started in: a rotation mid-drag must not leave a live width behind for it.
    private var dragShape: SplitColumnShape = .landscape
    private var lastSnapTarget: CGFloat?
    private var isHovering = false
    private var isTouching = false

    override init(frame: CGRect) {
        self.grabber = UIView()
        self.grabber.isUserInteractionEnabled = false
        self.grabber.alpha = 0.0
        self.grabber.layer.cornerRadius = SplitColumnDividerView.grabberSize.width / 2.0

        super.init(frame: frame)

        self.layer.contents = SplitColumnDividerView.transparentContents
        self.isHidden = true
        self.addSubview(self.grabber)

        // The window's keyboard pan and a navigation swipe must not start in the strip.
        self.disablesInteractiveKeyboardGestureRecognizer = true
        self.disablesInteractiveTransitionGestureRecognizer = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:)))
        pan.maximumNumberOfTouches = 1
        self.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(self.doubleTapGesture(_:)))
        doubleTap.numberOfTapsRequired = 2
        self.addGestureRecognizer(doubleTap)

        self.addInteraction(UIPointerInteraction(delegate: self))

        self.isAccessibilityElement = true
        self.accessibilityLabel = "Chat list width"
        self.accessibilityTraits = .adjustable
        self.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Reset Width", target: self, selector: #selector(self.accessibilityReset))]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var shape: SplitColumnShape {
        return SplitColumnShape(containerSize: self.containerSize)
    }

    func update(containerSize: CGSize, masterWidth: CGFloat, isEnabled: Bool, grabberColor: UIColor, transition: ContainedViewLayoutTransition) {
        self.containerSize = containerSize
        self.masterWidth = masterWidth
        if self.isDividerEnabled != isEnabled {
            self.isDividerEnabled = isEnabled
            self.isHidden = !isEnabled
            if !isEnabled, self.dragStartWidth != nil {
                // The window became too narrow (or compact) mid-drag: drop the drag, keep the stored width.
                self.dragStartWidth = nil
                self.store.cancelLive(for: self.dragShape)
            }
        }
        self.updateGrabberColor(grabberColor)
        self.accessibilityValue = "\(Int(masterWidth)) points"

        let grabberFrame = CGRect(x: SplitColumnDividerNode.listSideHitWidth - SplitColumnDividerView.grabberSize.width / 2.0, y: floor((containerSize.height - SplitColumnDividerView.grabberSize.height) / 2.0), width: SplitColumnDividerView.grabberSize.width, height: SplitColumnDividerView.grabberSize.height)
        transition.updateFrame(view: self.grabber, frame: grabberFrame)
        self.updateGrabberVisibility(animated: false)
    }

    func updateGrabberColor(_ color: UIColor) {
        self.grabber.backgroundColor = color
    }

    private func updateGrabberVisibility(animated: Bool) {
        let isVisible = self.isDividerEnabled && (self.isHovering || self.isTouching || self.dragStartWidth != nil)
        let alpha: CGFloat = isVisible ? 1.0 : 0.0
        if self.grabber.alpha == alpha {
            return
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: {
                self.grabber.alpha = alpha
            })
        } else {
            self.grabber.alpha = alpha
        }
    }

    /// Lays out the navigation controller that owns this split; the split container reads the width from the
    /// store (`splitMasterWidth(containerSize:division:)`). Found through the responder chain, so
    /// `NavigationController` needs no hook.
    private func requestNavigationLayout(_ transition: ContainedViewLayoutTransition) {
        var responder: UIResponder? = self.next
        while let current = responder {
            if let navigationController = current as? NavigationController {
                navigationController.requestLayout(transition: transition)
                return
            }
            responder = current.next
        }
    }

    // MARK: Hit testing

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !self.isDividerEnabled {
            return false
        }
        return super.point(inside: point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        self.isTouching = true
        self.updateGrabberVisibility(animated: true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        self.isTouching = false
        self.updateGrabberVisibility(animated: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        self.isTouching = false
        self.updateGrabberVisibility(animated: true)
    }

    // MARK: Gestures

    // UIView asks this for every recognizer attached to it.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            if !self.isDividerEnabled {
                return false
            }
            let velocity = pan.velocity(in: self)
            return abs(velocity.x) >= abs(velocity.y)
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func panGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            self.dragShape = self.shape
            self.dragStartWidth = self.masterWidth
            self.lastSnapTarget = nil
            self.hapticFeedback.prepareTap()
            self.updateGrabberVisibility(animated: true)
        case .changed:
            guard let dragStartWidth = self.dragStartWidth, self.shape == self.dragShape else {
                return
            }
            // Measured in the container, which does not move while the strip follows the finger.
            let translation = recognizer.translation(in: self.superview).x
            let result = SplitColumnWidth.dragged(startWidth: dragStartWidth, translation: translation, containerWidth: self.containerSize.width)
            if let target = result.target, target != self.lastSnapTarget {
                self.hapticFeedback.tap()
            }
            self.lastSnapTarget = result.target
            if result.width != self.masterWidth {
                self.store.setLive(result.width, for: self.dragShape)
                self.requestNavigationLayout(.immediate)
            }
        case .ended:
            if self.dragStartWidth != nil {
                self.dragStartWidth = nil
                if let width = self.store.liveWidth(for: self.dragShape) {
                    self.store.commit(width, for: self.dragShape)
                }
            }
            self.updateGrabberVisibility(animated: true)
        case .cancelled, .failed:
            if self.dragStartWidth != nil {
                self.dragStartWidth = nil
                self.store.cancelLive(for: self.dragShape)
                self.requestNavigationLayout(.animated(duration: 0.3, curve: .spring))
            }
            self.updateGrabberVisibility(animated: true)
        default:
            break
        }
    }

    @objc private func doubleTapGesture(_ recognizer: UITapGestureRecognizer) {
        guard self.isDividerEnabled, recognizer.state == .ended else {
            return
        }
        self.resetWidth()
    }

    private func resetWidth() {
        self.store.reset(for: self.shape)
        self.hapticFeedback.tap()
        self.requestNavigationLayout(.animated(duration: 0.35, curve: .spring))
    }

    // MARK: Pointer

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        if !self.isDividerEnabled {
            return nil
        }
        return defaultRegion
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // Without a content effect a shape is centred on the pointer, so the arrow is drawn around the origin.
        return UIPointerStyle(shape: .path(SplitColumnDividerView.resizeArrowPath()), constrainedAxes: [])
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, willEnter region: UIPointerRegion, animator: UIPointerInteractionAnimating) {
        self.isHovering = true
        self.updateGrabberVisibility(animated: true)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, willExit region: UIPointerRegion, animator: UIPointerInteractionAnimating) {
        self.isHovering = false
        self.updateGrabberVisibility(animated: true)
    }

    /// A ↔ double arrow, 22×12pt, centred on the origin.
    private static func resizeArrowPath() -> UIBezierPath {
        let halfWidth: CGFloat = 11.0
        let halfHeight: CGFloat = 6.0
        let head: CGFloat = 6.0
        let shaft: CGFloat = 1.5
        let path = UIBezierPath()
        path.move(to: CGPoint(x: -halfWidth, y: 0.0))
        path.addLine(to: CGPoint(x: -halfWidth + head, y: -halfHeight))
        path.addLine(to: CGPoint(x: -halfWidth + head, y: -shaft))
        path.addLine(to: CGPoint(x: halfWidth - head, y: -shaft))
        path.addLine(to: CGPoint(x: halfWidth - head, y: -halfHeight))
        path.addLine(to: CGPoint(x: halfWidth, y: 0.0))
        path.addLine(to: CGPoint(x: halfWidth - head, y: halfHeight))
        path.addLine(to: CGPoint(x: halfWidth - head, y: shaft))
        path.addLine(to: CGPoint(x: -halfWidth + head, y: shaft))
        path.addLine(to: CGPoint(x: -halfWidth + head, y: halfHeight))
        path.close()
        return path
    }

    // MARK: Accessibility

    override func accessibilityIncrement() {
        self.adjustByAccessibilitySteps(1)
    }

    override func accessibilityDecrement() {
        self.adjustByAccessibilitySteps(-1)
    }

    private func adjustByAccessibilitySteps(_ steps: Int) {
        guard self.isDividerEnabled else {
            return
        }
        let width = SplitColumnWidth.adjusted(current: self.masterWidth, steps: steps, containerWidth: self.containerSize.width)
        if width == self.masterWidth {
            return
        }
        self.store.commit(width, for: self.shape)
        self.accessibilityValue = "\(Int(width)) points"
        self.requestNavigationLayout(.animated(duration: 0.2, curve: .easeInOut))
    }

    @objc private func accessibilityReset() -> Bool {
        guard self.isDividerEnabled else {
            return false
        }
        self.resetWidth()
        return true
    }
}
