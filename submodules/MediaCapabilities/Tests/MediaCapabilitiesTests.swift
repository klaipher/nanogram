import XCTest
@testable import MediaCapabilities

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func hit(_ key: String) {
        self.lock.lock()
        self.counts[key, default: 0] += 1
        self.lock.unlock()
    }
    func count(_ key: String) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.counts[key] ?? 0
    }
}

final class MediaCapabilitiesTests: XCTestCase {
    func testEachDecodeProbeRunsOnce() {
        let counter = Counter()
        let capabilities = MediaCapabilities(decodeProbe: { codec in
            counter.hit(codec.rawValue)
            return codec == .av1
        }, encodeProbe: { [] })
        XCTAssertTrue(capabilities.isHardwareDecodeSupported(.av1))
        XCTAssertTrue(capabilities.isHardwareDecodeSupported(.av1))
        XCTAssertFalse(capabilities.isHardwareDecodeSupported(.vp9))
        XCTAssertEqual(counter.count("av1"), 1)
        XCTAssertEqual(counter.count("vp9"), 1)
        XCTAssertEqual(counter.count("h264"), 0)
    }

    func testEncodeListIsReadOnce() {
        let counter = Counter()
        let capabilities = MediaCapabilities(decodeProbe: { _ in false }, encodeProbe: {
            counter.hit("encode")
            return [.h264, .hevc]
        })
        XCTAssertTrue(capabilities.isHardwareEncodeSupported(.hevc))
        XCTAssertFalse(capabilities.isHardwareEncodeSupported(.av1))
        XCTAssertEqual(counter.count("encode"), 1)
    }

    func testReportNamesEveryCodec() {
        let capabilities = MediaCapabilities(decodeProbe: { $0 == .av1 }, encodeProbe: { [.hevc] })
        let lines = capabilities.reportLines()
        XCTAssertEqual(lines[0], "Media capabilities")
        XCTAssertEqual(lines[1], "hardware decode: h264=no hevc=no hevcWithAlpha=no vp9=no av1=yes")
        XCTAssertEqual(lines[2], "hardware encode: h264=no hevc=yes hevcWithAlpha=no vp9=no av1=no")
    }

    func testSystemReportRuns() {
        XCTAssertNoThrow(MediaCapabilities.shared.reportLines())
    }

    func testPassthroughNeedsHardwareForAv1Only() {
        XCTAssertTrue(VideoDecodePolicy.usesPassthrough(requested: true, isAv1: false, hardwareAv1: false))
        XCTAssertTrue(VideoDecodePolicy.usesPassthrough(requested: true, isAv1: true, hardwareAv1: true))
        XCTAssertFalse(VideoDecodePolicy.usesPassthrough(requested: true, isAv1: true, hardwareAv1: false))
        XCTAssertFalse(VideoDecodePolicy.usesPassthrough(requested: false, isAv1: false, hardwareAv1: true))
    }

    func testHardwareAccelerationRules() {
        XCTAssertTrue(VideoDecodePolicy.usesHardwareAcceleration(requested: true, isAv1: false, hardwareAv1: false, longSide: 1920, minimumLongSide: 1280))
        XCTAssertFalse(VideoDecodePolicy.usesHardwareAcceleration(requested: true, isAv1: false, hardwareAv1: false, longSide: 640, minimumLongSide: 1280))
        XCTAssertTrue(VideoDecodePolicy.usesHardwareAcceleration(requested: true, isAv1: true, hardwareAv1: true, longSide: 1920, minimumLongSide: 0))
        XCTAssertFalse(VideoDecodePolicy.usesHardwareAcceleration(requested: true, isAv1: true, hardwareAv1: false, longSide: 1920, minimumLongSide: 0))
        XCTAssertFalse(VideoDecodePolicy.usesHardwareAcceleration(requested: false, isAv1: false, hardwareAv1: true, longSide: 4000, minimumLongSide: 0))
    }

    func testDecodePathIsReportedOncePerPair() {
        let reporter = DecodePathReporter()
        XCTAssertEqual(reporter.firstReport(codec: "av1", hardware: false), "decode codec=av1 path=software")
        XCTAssertNil(reporter.firstReport(codec: "av1", hardware: false))
        XCTAssertEqual(reporter.firstReport(codec: "av1", hardware: true), "decode codec=av1 path=hardware")
        XCTAssertEqual(reporter.firstReport(codec: "hevc", hardware: true), "decode codec=hevc path=hardware")
    }
}
