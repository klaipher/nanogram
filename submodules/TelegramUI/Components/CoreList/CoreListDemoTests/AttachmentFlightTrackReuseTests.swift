import XCTest
import QuartzCore
@testable import CoreListDemo

/// `installAttachmentFlightTracks` runs at the end of every `renderAttachments`, which a keyframe
/// flight reaches on every sampling tick and every rebalance. Re-adding an identical track there costs
/// a CAKeyframeAnimation, two arrays of boxed NSNumbers and a commit to the render server per moving
/// attachment per frame, and buys nothing: same values, keyTimes, duration and (past) beginTime is the
/// same animation at the same phase. These tests pin that an unchanged track is left in place, that
/// anything which changes the emitted animation reinstalls it, and that what is installed is exactly
/// what the composed keyframe describes.
final class AttachmentFlightTrackReuseTests: XCTestCase {
    private func groupedItems(count: Int = 60, groupSize: Int = 5) -> [CoreListItem] {
        (0..<count).map { index in
            let group = index / groupSize
            return AttachedItem(id: index, height: 50,
                                attachedItems: ["date\(group)": FixedHeightAttachment(
                                    label: "group\(group)", height: 30,
                                    placement: .overlay, edge: .top, isFloating: true)])
        }
    }

    /// A ramp at the physics bake rate (120 vertices/s), like a real fling.
    private func rampTrajectory(from: CGFloat, to: CGFloat, duration: TimeInterval = 2.5) -> Trajectory {
        let steps = Int(duration * 120)
        return Trajectory(samples: (0...steps).map { i in
            let phase = CGFloat(i) / CGFloat(steps)
            return .init(t: duration * Double(phase), offset: from + (to - from) * phase, velocity: 0)
        })
    }

    private func flightTrack(_ attachment: CoreVirtualListView.Window.Attachment) -> CAKeyframeAnimation? {
        attachment.view.layer.animation(forKey: CoreVirtualListView.attachmentFlightKey) as? CAKeyframeAnimation
    }

    /// The installed animation must be exactly the one the pre-cache code built.
    private func assertTrack(_ animation: CAKeyframeAnimation?,
                             matches composed: (values: [CGFloat], keyTimes: [Double]),
                             flight: ScrollFlight,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let animation else {
            XCTFail("expected a flight track", file: file, line: line)
            return
        }
        XCTAssertEqual(animation.keyPath, "position.y", file: file, line: line)
        XCTAssertTrue(animation.isAdditive, file: file, line: line)
        XCTAssertEqual(animation.calculationMode, .linear, file: file, line: line)
        XCTAssertEqual(animation.duration, flight.trajectory.duration, file: file, line: line)
        XCTAssertEqual(animation.beginTime, flight.beginTime, file: file, line: line)
        let values = (animation.values as? [NSNumber])?.map(\.doubleValue)
        XCTAssertEqual(values, composed.values.map { Double($0) }, file: file, line: line)
        let keyTimes = animation.keyTimes?.map(\.doubleValue)
        XCTAssertEqual(keyTimes, composed.keyTimes, file: file, line: line)
    }

    private func movingAttachments(_ fixture: VirtualListFixture,
                                   flight: ScrollFlight) -> [CoreVirtualListView.Window.Attachment] {
        let window = fixture.activeWindow
        return window.attachments.filter { attachment in
            fixture.listView.attachmentMap(attachment, window: window)
                .composedKeyframe(trajectory: flight.trajectory, coordinateShift: flight.coordinateShift)
                .values.contains { abs($0) > 1e-9 }
        }
    }

    func testAnUnchangedFlightLeavesTheInstalledTrackInPlace() {
        let fixture = VirtualListFixture(items: groupedItems(), emitsCA: true)
        let live = fixture.listView.engine.offset
        let flight = ScrollFlight(trajectory: rampTrajectory(from: live, to: live + 400), beginTime: 3)
        fixture.listView.activeScrollFlight = flight
        fixture.listView.renderAttachments()

        let moving = movingAttachments(fixture, flight: flight)
        XCTAssertFalse(moving.isEmpty, "precondition: the flight must move at least one attachment")
        let installed = moving.map { flightTrack($0) }
        XCTAssertTrue(installed.allSatisfy { $0 != nil })

        fixture.listView.renderAttachments()
        fixture.listView.renderAttachments()

        let window = fixture.activeWindow
        for (attachment, before) in zip(moving, installed) {
            let after = flightTrack(attachment)
            XCTAssertTrue(after === before, "an identical track must not be removed and re-added")
            let composed = fixture.listView.attachmentMap(attachment, window: window)
                .composedKeyframe(trajectory: flight.trajectory, coordinateShift: flight.coordinateShift)
            assertTrack(after, matches: composed, flight: flight)
        }
    }

    func testANewTrajectoryReinstallsTheTrack() {
        let fixture = VirtualListFixture(items: groupedItems(), emitsCA: true)
        let live = fixture.listView.engine.offset
        let first = ScrollFlight(trajectory: rampTrajectory(from: live, to: live + 400), beginTime: 3)
        fixture.listView.activeScrollFlight = first
        fixture.listView.renderAttachments()
        let moving = movingAttachments(fixture, flight: first)
        XCTAssertFalse(moving.isEmpty)
        let installed = moving.map { flightTrack($0) }

        // A rebake keeps its past origin and changes the path: same beginTime, different samples.
        let rebaked = ScrollFlight(trajectory: rampTrajectory(from: live, to: live + 300, duration: 2.0),
                                   beginTime: 3)
        fixture.listView.activeScrollFlight = rebaked
        fixture.listView.renderAttachments()

        let window = fixture.activeWindow
        for (attachment, before) in zip(moving, installed) {
            let composed = fixture.listView.attachmentMap(attachment, window: window)
                .composedKeyframe(trajectory: rebaked.trajectory, coordinateShift: rebaked.coordinateShift)
            guard composed.values.contains(where: { abs($0) > 1e-9 }) else {
                XCTAssertNil(flightTrack(attachment))
                continue
            }
            XCTAssertFalse(flightTrack(attachment) === before, "a changed flight must reinstall")
            assertTrack(flightTrack(attachment), matches: composed, flight: rebaked)
        }
    }

    func testABeginTimeChangeAloneReinstallsTheTrack() {
        let fixture = VirtualListFixture(items: groupedItems(), emitsCA: true)
        let live = fixture.listView.engine.offset
        let trajectory = rampTrajectory(from: live, to: live + 400)
        let first = ScrollFlight(trajectory: trajectory, beginTime: 3)
        fixture.listView.activeScrollFlight = first
        fixture.listView.renderAttachments()
        let moving = movingAttachments(fixture, flight: first)
        let installed = moving.map { flightTrack($0) }

        let relaunched = ScrollFlight(trajectory: trajectory, beginTime: 4)
        fixture.listView.activeScrollFlight = relaunched
        fixture.listView.renderAttachments()

        let window = fixture.activeWindow
        for (attachment, before) in zip(moving, installed) {
            XCTAssertFalse(flightTrack(attachment) === before)
            let composed = fixture.listView.attachmentMap(attachment, window: window)
                .composedKeyframe(trajectory: trajectory)
            assertTrack(flightTrack(attachment), matches: composed, flight: relaunched)
        }
    }

    func testACoordinateShiftReinstallsWithTheShiftedValues() {
        let fixture = VirtualListFixture(items: groupedItems(), emitsCA: true)
        let live = fixture.listView.engine.offset
        let trajectory = rampTrajectory(from: live, to: live + 400)
        let first = ScrollFlight(trajectory: trajectory, beginTime: 3)
        fixture.listView.activeScrollFlight = first
        fixture.listView.renderAttachments()

        var shifted = first
        shifted.coordinateShift = 120
        fixture.listView.activeScrollFlight = shifted
        fixture.listView.renderAttachments()

        let window = fixture.activeWindow
        var sawTrack = false
        for attachment in window.attachments {
            let composed = fixture.listView.attachmentMap(attachment, window: window)
                .composedKeyframe(trajectory: trajectory, coordinateShift: 120)
            if composed.values.contains(where: { abs($0) > 1e-9 }) {
                sawTrack = true
                assertTrack(flightTrack(attachment), matches: composed, flight: shifted)
            } else {
                XCTAssertNil(flightTrack(attachment))
            }
        }
        XCTAssertTrue(sawTrack, "precondition: the shifted flight must still move an attachment")
    }

    func testATrackRemovedFromTheLayerIsInstalledAgain() {
        let fixture = VirtualListFixture(items: groupedItems(), emitsCA: true)
        let live = fixture.listView.engine.offset
        let flight = ScrollFlight(trajectory: rampTrajectory(from: live, to: live + 400), beginTime: 3)
        fixture.listView.activeScrollFlight = flight
        fixture.listView.renderAttachments()
        let moving = movingAttachments(fixture, flight: flight)
        XCTAssertFalse(moving.isEmpty)

        // Anything that strips the layer (a rebind, a completed animation) must not be mistaken for
        // a track that is still playing.
        for attachment in moving {
            attachment.view.layer.removeAllAnimations()
        }
        fixture.listView.renderAttachments()

        let window = fixture.activeWindow
        for attachment in moving {
            let composed = fixture.listView.attachmentMap(attachment, window: window)
                .composedKeyframe(trajectory: flight.trajectory)
            assertTrack(flightTrack(attachment), matches: composed, flight: flight)
        }
    }

    func testEndingTheFlightRemovesTheTrackAndANewFlightInstallsOne() {
        let fixture = VirtualListFixture(items: groupedItems(), emitsCA: true)
        let live = fixture.listView.engine.offset
        let flight = ScrollFlight(trajectory: rampTrajectory(from: live, to: live + 400), beginTime: 3)
        fixture.listView.activeScrollFlight = flight
        fixture.listView.renderAttachments()
        let moving = movingAttachments(fixture, flight: flight)
        XCTAssertFalse(moving.isEmpty)

        fixture.listView.activeScrollFlight = nil
        fixture.listView.renderAttachments()
        for attachment in fixture.activeWindow.attachments {
            XCTAssertNil(flightTrack(attachment))
        }

        // The identical flight again must not be skipped because of a record left from the first.
        fixture.listView.activeScrollFlight = flight
        fixture.listView.renderAttachments()
        let window = fixture.activeWindow
        for attachment in moving {
            let composed = fixture.listView.attachmentMap(attachment, window: window)
                .composedKeyframe(trajectory: flight.trajectory)
            assertTrack(flightTrack(attachment), matches: composed, flight: flight)
        }
    }

    func testDecisionRule() {
        let record = AttachmentFlightTrackRecord(values: [1, 2, 0], keyTimes: [0, 0.5, 1],
                                                 duration: 2, beginTime: 3)
        XCTAssertTrue(record.matches(values: [1, 2, 0], keyTimes: [0, 0.5, 1], duration: 2, beginTime: 3))
        XCTAssertFalse(record.matches(values: [1, 2.5, 0], keyTimes: [0, 0.5, 1], duration: 2, beginTime: 3))
        XCTAssertFalse(record.matches(values: [1, 2, 0], keyTimes: [0, 0.4, 1], duration: 2, beginTime: 3))
        XCTAssertFalse(record.matches(values: [1, 2, 0], keyTimes: [0, 0.5, 1], duration: 2.1, beginTime: 3))
        XCTAssertFalse(record.matches(values: [1, 2, 0], keyTimes: [0, 0.5, 1], duration: 2, beginTime: 3.5))
    }

    /// Micro-benchmark of the hot function during a flight: the tick-by-tick case, where the flight
    /// and the window are unchanged between calls. Prints the per-call cost; not an assertion.
    func testBenchmarkInstallDuringAnUnchangedFlight() {
        let fixture = VirtualListFixture(items: groupedItems(count: 120), emitsCA: true)
        let live = fixture.listView.engine.offset
        let flight = ScrollFlight(trajectory: rampTrajectory(from: live, to: live + 400), beginTime: 3)
        fixture.listView.activeScrollFlight = flight
        let window = fixture.activeWindow
        let movingCount = movingAttachments(fixture, flight: flight).count
        fixture.listView.installAttachmentFlightTracks(window: window)

        let iterations = 300
        var best = Double.infinity
        for _ in 0..<5 {
            let start = CACurrentMediaTime()
            for _ in 0..<iterations {
                fixture.listView.installAttachmentFlightTracks(window: window)
            }
            best = min(best, (CACurrentMediaTime() - start) / Double(iterations))
        }
        print("ATTACHMENT_FLIGHT_BENCH attachments=\(window.attachments.count) moving=\(movingCount) "
              + "samples=\(flight.trajectory.samples.count) perCall=\(String(format: "%.1f", best * 1e6))us")
    }
}
