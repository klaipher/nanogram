import Foundation
import XCTest
@testable import TelegramCallsUI

/// Pins the lifetime rule of the Metal video renderer: the CVMetalTextures and the pixel buffer
/// behind a frame stay alive until the command buffer that samples them has completed, even when
/// a newer frame replaces them as the "current" one in the meantime.
final class GPUFrameResourceLeaseTests: XCTestCase {
    private final class FakeResource {}

    /// Stands in for `MTLCommandBuffer.addCompletedHandler`.
    private final class FakeCommandBuffer {
        private var handlers: [() -> Void] = []

        func addCompletedHandler(_ handler: @escaping () -> Void) {
            self.handlers.append(handler)
        }

        func complete() {
            let handlers = self.handlers
            self.handlers = []
            for handler in handlers {
                handler()
            }
        }
    }

    func testResourcesOutliveTheirOwnerUntilTheGPUCompletes() {
        let commandBuffer = FakeCommandBuffer()
        weak var weakResource: FakeResource?
        do {
            let resource = FakeResource()
            weakResource = resource
            let lease = GPUFrameResourceLease(resources: [resource])
            lease.hold(until: commandBuffer.addCompletedHandler)
        }
        XCTAssertNotNil(weakResource, "dropped while the GPU may still read it")
        commandBuffer.complete()
        XCTAssertNil(weakResource, "kept after the GPU is done")
    }

    func testReplacingTheCurrentFrameDoesNotReleaseAnEncodedOne() {
        let commandBuffer = FakeCommandBuffer()
        var state = GPUFrameResourceState()
        weak var first: FakeResource?
        do {
            let resource = FakeResource()
            first = resource
            state.update(resources: [resource])
        }
        state.currentLease?.hold(until: commandBuffer.addCompletedHandler)
        state.update(resources: [FakeResource()])
        XCTAssertNotNil(first, "the newer frame released what the in-flight frame samples")
        commandBuffer.complete()
        XCTAssertNil(first)
    }

    func testAFrameThatWasNeverEncodedIsReleasedWhenReplaced() {
        var state = GPUFrameResourceState()
        weak var first: FakeResource?
        do {
            let resource = FakeResource()
            first = resource
            state.update(resources: [resource])
        }
        state.update(resources: [FakeResource()])
        XCTAssertNil(first, "frames dropped before drawing must not accumulate")
    }

    func testEachCommandBufferKeepsItsOwnFrame() {
        let early = FakeCommandBuffer()
        let late = FakeCommandBuffer()
        var state = GPUFrameResourceState()
        weak var first: FakeResource?
        weak var second: FakeResource?
        do {
            let a = FakeResource()
            first = a
            state.update(resources: [a])
            state.currentLease?.hold(until: early.addCompletedHandler)
            let b = FakeResource()
            second = b
            state.update(resources: [b])
            state.currentLease?.hold(until: late.addCompletedHandler)
        }
        early.complete()
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        late.complete()
        state.clear()
        XCTAssertNil(second)
    }

    func testClearingDropsTheCurrentFrame() {
        var state = GPUFrameResourceState()
        weak var resource: FakeResource?
        do {
            let value = FakeResource()
            resource = value
            state.update(resources: [value])
        }
        XCTAssertNotNil(resource)
        state.clear()
        XCTAssertNil(resource)
        XCTAssertNil(state.currentLease)
    }
}
