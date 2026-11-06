import XCTest
@testable import CoreListDemo

/// Pins `ListMembership` against the quadratic algorithms it replaced in `render()` and
/// `rebalanceActiveWindow()`: same views removed, same surviving order, same z-order after the add loop.
final class ListMembershipTests: XCTestCase {
    // MARK: Reference implementations (verbatim shape of the old code)

    private func referenceStale(subviews: [UIView], keeping: [UIView]) -> [UIView] {
        subviews.filter { subview in !keeping.contains(where: { $0 === subview }) }
    }

    private func referencePromoted(windowIdentities: [AnyHashable], carries: [AnyHashable: Int]) -> Set<AnyHashable> {
        Set(windowIdentities).intersection(carries.keys)
    }

    /// The old `render()` membership step run on a real container: remove stale subviews, then
    /// append every window view that is not already in the container, in window order.
    private func renderOld(container: UIView, window: [UIView]) -> [UIView] {
        var removed: [UIView] = []
        for subview in container.subviews where !window.contains(where: { $0 === subview }) {
            removed.append(subview)
            subview.removeFromSuperview()
        }
        for view in window where view.superview !== container {
            container.addSubview(view)
        }
        return removed
    }

    private func renderNew(container: UIView, window: [UIView]) -> [UIView] {
        var removed: [UIView] = []
        for subview in ListMembership.staleSubviews(in: container.subviews, keeping: window) {
            removed.append(subview)
            subview.removeFromSuperview()
        }
        for view in window where view.superview !== container {
            container.addSubview(view)
        }
        return removed
    }

    // MARK: Tests

    func testEmptyInputs() {
        XCTAssertTrue(ListMembership.staleSubviews(in: [], keeping: []).isEmpty)
        XCTAssertTrue(ListMembership.staleSubviews(in: [], keeping: [UIView()]).isEmpty)
        let a = UIView()
        XCTAssertEqual(ListMembership.staleSubviews(in: [a], keeping: []).count, 1)
    }

    func testReferenceIdentityNotEquality() {
        // Two distinct views with identical frames are not interchangeable.
        let a = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        XCTAssertTrue(ListMembership.staleSubviews(in: [a, b], keeping: [a]).first === b)
    }

    func testStaleSubviewsMatchReferenceOnRandomInputs() {
        var rng = SeededRNG(seed: 0xC0DE_0001)
        for _ in 0..<300 {
            let pool = (0..<rng.int(in: 1..<40)).map { _ in UIView() }
            let subviews = pool.filter { _ in rng.bool() }.shuffled(using: &rng)
            let keeping = pool.filter { _ in rng.bool() }.shuffled(using: &rng)
            let expected = referenceStale(subviews: subviews, keeping: keeping)
            let actual = ListMembership.staleSubviews(in: subviews, keeping: keeping)
            XCTAssertEqual(actual.count, expected.count)
            for (x, y) in zip(actual, expected) { XCTAssertTrue(x === y) }
        }
    }

    /// The whole membership step on two parallel containers: identical removed sets (in order) and an
    /// identical final subview order, i.e. identical z-order.
    func testRenderMembershipStepProducesIdenticalSubviewOrderAndRemovals() {
        var rng = SeededRNG(seed: 0xC0DE_0002)
        for round in 0..<300 {
            let count = rng.int(in: 1..<50)
            let oldPool = (0..<count).map { _ in UIView() }
            let newPool = (0..<count).map { _ in UIView() }
            let oldContainer = UIView()
            let newContainer = UIView()

            // Pre-existing container content: a random ordered subset, plus stray views (an overlay).
            let present = (0..<count).filter { _ in rng.bool() }.shuffled(using: &rng)
            for i in present {
                oldContainer.addSubview(oldPool[i])
                newContainer.addSubview(newPool[i])
            }
            // Next window: a random ordered subset of the pool (a scroll step keeps most of it).
            let windowIdx = (0..<count).filter { _ in rng.bool(probability: 0.7) }
            let removedOld = renderOld(container: oldContainer, window: windowIdx.map { oldPool[$0] })
            let removedNew = renderNew(container: newContainer, window: windowIdx.map { newPool[$0] })

            func indices(_ views: [UIView], in pool: [UIView]) -> [Int] {
                views.map { v in pool.firstIndex(where: { $0 === v }) ?? -1 }
            }
            XCTAssertEqual(indices(removedNew, in: newPool), indices(removedOld, in: oldPool), "round \(round)")
            XCTAssertEqual(indices(newContainer.subviews, in: newPool),
                           indices(oldContainer.subviews, in: oldPool), "round \(round)")
            XCTAssertFalse(indices(newContainer.subviews, in: newPool).contains(-1))
        }
    }

    func testPromotedIdentitiesMatchReference() {
        var rng = SeededRNG(seed: 0xC0DE_0003)
        for _ in 0..<300 {
            let window: [AnyHashable] = (0..<rng.int(in: 0..<60)).map { _ in AnyHashable(rng.int(in: 0..<100)) }
            var carries: [AnyHashable: Int] = [:]
            for _ in 0..<rng.int(in: 0..<10) { carries[AnyHashable(rng.int(in: 0..<100))] = 1 }
            XCTAssertEqual(ListMembership.promotedIdentities(windowIdentities: window, carries: carries),
                           referencePromoted(windowIdentities: window, carries: carries))
        }
    }

    func testPromotedIdentitiesWithNoCarriesIsEmptyEvenForANonEmptyWindow() {
        XCTAssertTrue(ListMembership.promotedIdentities(windowIdentities: [1, 2, 3],
                                                        carries: [AnyHashable: Int]()).isEmpty)
    }
}
