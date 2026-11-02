import XCTest
import UIKit
import AsyncDisplayKit
@testable import Display

/// Counts how often it leaves and enters a window. UIKit tells every view of a moved subtree, so this is the cost
/// of a move that changes window: `_didMoveFromWindow:toWindow:` over the whole subtree, the work device traces
/// showed at the end of every push and pop (`NavigationBarTransitionLayer.putBack`, 7-17 ms on an iPhone 17 Pro Max).
private final class WindowProbeView: UIView {
    var leftWindow = 0
    var enteredWindow = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window == nil {
            self.leftWindow += 1
        } else {
            self.enteredWindow += 1
        }
    }
}

/// Mirrors the real bars' putBack (`NavigationBarNode`, `ChatListNavigationBar`): the content goes back at index 0,
/// filling the bar.
private final class BarSource: NavigationBarTransitionSource {
    let containingView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 390.0, height: 100.0))
    let contentView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 390.0, height: 100.0))
    let background = UIView()
    var probes: [WindowProbeView] = []
    var transitionContentFrameUpdated: ((CGRect) -> Void)?

    init(subviewCount: Int) {
        self.containingView.addSubview(self.background)
        self.containingView.insertSubview(self.contentView, at: 0)
        // A bar's content: a few levels of title, buttons and their insides.
        var parent: UIView = self.contentView
        for index in 0 ..< subviewCount {
            let probe = WindowProbeView(frame: CGRect(x: CGFloat(index % 10) * 30.0, y: 10.0, width: 28.0, height: 28.0))
            parent.addSubview(probe)
            self.probes.append(probe)
            if index % 4 == 3 {
                parent = probe
            }
        }
    }

    func takeView() -> NavigationBarTransitionTakeViewInfo? {
        return NavigationBarTransitionTakeViewInfo(containingView: self.containingView, contentView: self.contentView)
    }

    func putBack() {
        self.containingView.insertSubview(self.contentView, at: 0)
        self.contentView.frame = CGRect(origin: CGPoint(), size: self.containingView.bounds.size)
    }

    func updateTransition(role: NavigationBarTransitionRole?, fraction: CGFloat, transition: ContainedViewLayoutTransition) {
    }
}

private final class InertRenderer: NavigationBarTransitionRenderer {
    let backdropView = UIView()
    let rowView = UIView()
    var isGlassAnimating = false
    var glassSettled: (() -> Void)?

    func update(size: CGSize, fraction: CGFloat, bottomFrame: CGRect, topFrame: CGRect, transition: ContainedViewLayoutTransition) {
    }

    func end() {
    }

    func animate(size: CGSize, timeline: NavigationTransitionTimeline, bottomFrame: CGRect, topFrame: CGRect) {
    }

    func beginTransition(isInteractive: Bool, toTop: Bool) {
    }

    func endInteraction(towardTop: Bool) {
    }

    func beginInteraction() {
    }
}

/// One window for the whole process: a logic-test process traps after the suite if a window it made is freed.
private let testWindow = UIWindow(frame: CGRect(x: 0.0, y: 0.0, width: 390.0, height: 844.0))

final class NavigationBarTransitionPutBackTests: XCTestCase {
    private struct Scene {
        let window: UIWindow
        let layer: NavigationBarTransitionLayer
        let bottom: BarSource
        let top: BarSource
        let bottomScreen: UIView
        let topScreen: UIView
    }

    private func makeScene(subviewCount: Int) -> Scene {
        let window = testWindow
        window.subviews.forEach { $0.removeFromSuperview() }
        let container = UIView(frame: window.bounds)
        window.addSubview(container)
        let bottomScreen = UIView(frame: container.bounds)
        let topScreen = UIView(frame: container.bounds)
        container.addSubview(bottomScreen)
        container.addSubview(topScreen)
        let bottom = BarSource(subviewCount: subviewCount)
        let top = BarSource(subviewCount: subviewCount)
        bottomScreen.addSubview(bottom.containingView)
        topScreen.addSubview(top.containingView)
        let layer = NavigationBarTransitionLayer(renderer: InertRenderer(), bottom: (bottom, bottom.takeView()!, bottomScreen), top: (top, top.takeView()!, topScreen))
        layer.frame = container.bounds
        container.addSubview(layer.view)
        return Scene(window: window, layer: layer, bottom: bottom, top: top, bottomScreen: bottomScreen, topScreen: topScreen)
    }

    /// The lifted contents stay in the window while they go back to their bars: one reparent within the window
    /// instead of leaving it with their clip and entering it again.
    func testPutBackKeepsTheContentsInTheWindow() {
        let scene = self.makeScene(subviewCount: 12)
        for source in [scene.bottom, scene.top] {
            XCTAssertTrue(source.contentView.window === scene.window, "lifted into the layer, in the window")
            for probe in source.probes {
                probe.leftWindow = 0
                probe.enteredWindow = 0
            }
        }

        scene.layer.putBack()

        for source in [scene.bottom, scene.top] {
            XCTAssertEqual(source.probes.map(\.leftWindow).reduce(0, +), 0, "never left the window")
            XCTAssertEqual(source.probes.map(\.enteredWindow).reduce(0, +), 0)
        }
        withExtendedLifetime(scene) {}
    }

    /// The hierarchy and frames after putBack are what they were before the bars were lifted.
    func testPutBackRestoresTheBarsExactly() {
        let reference = (bottom: BarSource(subviewCount: 12), top: BarSource(subviewCount: 12))
        let scene = self.makeScene(subviewCount: 12)
        scene.layer.putBack()

        for (source, original) in [(scene.bottom, reference.bottom), (scene.top, reference.top)] {
            XCTAssertTrue(source.contentView.superview === source.containingView)
            XCTAssertEqual(source.containingView.subviews.firstIndex(of: source.contentView), 0)
            XCTAssertTrue(source.containingView.subviews.last === source.background)
            XCTAssertEqual(source.contentView.frame, original.contentView.frame)
            XCTAssertEqual(source.probes.map(\.frame), original.probes.map(\.frame))
            XCTAssertEqual(source.probes.map { $0.superview === source.contentView }, original.probes.map { $0.superview === original.contentView })
        }
        // Nothing of the transition is left above the screens but its (empty) layer.
        XCTAssertTrue(scene.layer.view.subviews.allSatisfy { $0.subviews.isEmpty })
        XCTAssertFalse(scene.bottom.contentView.isDescendant(of: scene.layer.view))
        XCTAssertFalse(scene.top.contentView.isDescendant(of: scene.layer.view))
    }

    /// Simulator timing of putBack for bar contents of a realistic size (a chat-list header with its title, search
    /// field, story strip and buttons runs to a few hundred views). Prints the median; the device number is the
    /// trace's NavigationBarTransitionLayer.putBack.
    func testPutBackTiming() {
        var samples: [Double] = []
        for _ in 0 ..< 15 {
            let scene = self.makeScene(subviewCount: 300)
            let start = CACurrentMediaTime()
            scene.layer.putBack()
            samples.append((CACurrentMediaTime() - start) * 1000.0)
            withExtendedLifetime(scene) {}
        }
        samples.sort()
        NSLog("%@", "NavigationBarTransitionPutBack: median \(String(format: "%.3f", samples[samples.count / 2])) ms, min \(String(format: "%.3f", samples[0])) ms for 2 x 300 views")
    }
}
