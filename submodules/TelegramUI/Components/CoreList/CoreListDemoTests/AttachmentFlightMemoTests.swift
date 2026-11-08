import XCTest
import QuartzCore
@testable import CoreListDemo

/// `installAttachmentFlightTracks` memoizes the composed keyframe per attachment layer: with the same map, the same
/// trajectory samples and the same coordinate shift, nothing is recomputed (counted), and the outcome (installed tracks,
/// absence of tracks for rigid attachments) is exactly what a recomputation produces.
final class AttachmentFlightMemoTests: XCTestCase {
    private func groupedItems(count: Int = 60, groupSize: Int = 5) -> [CoreListItem] {
        (0..<count).map { index in
            let group = index / groupSize
            return AttachedItem(id: index, height: 50,
                                attachedItems: ["date\(group)": FixedHeightAttachment(
                                    label: "group\(group)", height: 30,
                                    placement: .overlay, edge: .top, isFloating: true)])
        }
    }

    private func rampTrajectory(from: CGFloat, to: CGFloat, duration: TimeInterval = 2.5) -> Trajectory {
        let steps = Int(duration * 120)
        return Trajectory(samples: (0...steps).map { i in
            let phase = CGFloat(i) / CGFloat(steps)
            return .init(t: duration * Double(phase), offset: from + (to - from) * phase, velocity: 0)
        })
    }

    private func track(_ attachment: CoreVirtualListView.Window.Attachment) -> CAKeyframeAnimation? {
        attachment.view.layer.animation(forKey: CoreVirtualListView.attachmentFlightKey) as? CAKeyframeAnimation
    }

    private func started() -> (VirtualListFixture, ScrollFlight) {
        let fixture = VirtualListFixture(items: groupedItems(), emitsCA: true)
        let live = fixture.listView.engine.offset
        let flight = ScrollFlight(trajectory: rampTrajectory(from: live, to: live + 400), beginTime: 3)
        fixture.listView.activeScrollFlight = flight
        fixture.listView.renderAttachments()
        return (fixture, flight)
    }

    func testRepeatedRendersOfAnUnchangedFlightRecomputeNothing() {
        let (fixture, flight) = started()
        let list = fixture.listView
        let attachments = fixture.activeWindow.attachments
        XCTAssertFalse(attachments.isEmpty)
        let tracksBefore = attachments.map { track($0) }
        let missesBefore = list.attachmentFlightMemoMissCount
        let hitsBefore = list.attachmentFlightMemoHitCount

        for _ in 0..<5 { list.renderAttachments() }

        XCTAssertEqual(list.attachmentFlightMemoMissCount, missesBefore, "no composed keyframe may be rebuilt")
        XCTAssertEqual(list.attachmentFlightMemoHitCount - hitsBefore, 5 * attachments.count)
        for (attachment, before) in zip(attachments, tracksBefore) {
            XCTAssertTrue(track(attachment) === before)
            let composed = list.attachmentMap(attachment, window: fixture.activeWindow)
                .composedKeyframe(trajectory: flight.trajectory, coordinateShift: flight.coordinateShift)
            let moves = composed.values.contains { abs($0) > 1e-9 }
            XCTAssertEqual(track(attachment) != nil, moves, "installed tracks equal what a recomputation decides")
        }
    }

    func testACoordinateShiftInvalidatesTheMemoAndRebuildsTheTracks() {
        let (fixture, flight) = started()
        let list = fixture.listView
        var shifted = flight
        shifted.coordinateShift = 37
        list.activeScrollFlight = shifted
        let missesBefore = list.attachmentFlightMemoMissCount
        list.renderAttachments()
        XCTAssertEqual(list.attachmentFlightMemoMissCount - missesBefore, fixture.activeWindow.attachments.count)

        for attachment in fixture.activeWindow.attachments {
            let composed = list.attachmentMap(attachment, window: fixture.activeWindow)
                .composedKeyframe(trajectory: shifted.trajectory, coordinateShift: 37)
            if composed.values.contains(where: { abs($0) > 1e-9 }) {
                let values = (track(attachment)?.values as? [NSNumber])?.map(\.doubleValue)
                XCTAssertEqual(values, composed.values.map { Double($0) })
            } else {
                XCTAssertNil(track(attachment))
            }
        }
    }

    func testANewTrajectoryBufferMisses() {
        let (fixture, flight) = started()
        let list = fixture.listView
        let live = flight.trajectory.samples[0].offset
        list.activeScrollFlight = ScrollFlight(trajectory: rampTrajectory(from: live, to: live + 300, duration: 2.0), beginTime: 3)
        let missesBefore = list.attachmentFlightMemoMissCount
        list.renderAttachments()
        XCTAssertEqual(list.attachmentFlightMemoMissCount - missesBefore, fixture.activeWindow.attachments.count)
    }

    func testAMovedBandOrInsetInvalidatesTheMemo() {
        let (fixture, _) = started()
        let list = fixture.listView
        let missesBefore = list.attachmentFlightMemoMissCount
        list.updateAttachmentDisplayInsets(UIEdgeInsets(top: 120, left: 0, bottom: 0, right: 0))
        XCTAssertGreaterThan(list.attachmentFlightMemoMissCount, missesBefore,
                             "a display-area change alters the anchor, so the maps differ")
    }

    func testARemovedTrackIsReinstalledDespiteTheMemo() {
        let (fixture, _) = started()
        let list = fixture.listView
        let window = fixture.activeWindow
        guard let moving = window.attachments.first(where: { track($0) != nil }) else {
            return XCTFail("precondition: one attachment must be moving")
        }
        moving.view.layer.removeAnimation(forKey: CoreVirtualListView.attachmentFlightKey)
        list.renderAttachments()
        XCTAssertNotNil(track(moving), "the memo never outranks the layer: a stripped track comes back")
    }

    func testAttachmentOffsetMapIdentity() {
        func map(anchor: CGFloat = 10, gap: CGFloat? = nil, partnerAnchor: CGFloat = 0) -> AttachmentOffsetMap {
            let partner = AttachmentOffsetMap(bandTop: 0, bandBottom: 100, height: 20, anchor: partnerAnchor,
                                              contentBase: 0, edge: .top, isFloating: true)
            return AttachmentOffsetMap(bandTop: 0, bandBottom: 200, height: 30, anchor: anchor, contentBase: 5,
                                       edge: .top, isFloating: true,
                                       yield: gap.map { (partners: [partner], gap: $0) })
        }
        XCTAssertTrue(map().isIdentical(to: map()))
        XCTAssertFalse(map().isIdentical(to: map(anchor: 11)))
        XCTAssertTrue(map(gap: 4).isIdentical(to: map(gap: 4)))
        XCTAssertFalse(map(gap: 4).isIdentical(to: map(gap: 5)))
        XCTAssertFalse(map(gap: 4).isIdentical(to: map()))
        XCTAssertFalse(map(gap: 4).isIdentical(to: map(gap: 4, partnerAnchor: 1)))
    }
}
