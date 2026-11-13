import XCTest
@testable import CrashReporting

final class MemoryExceptionReportTests: XCTestCase {
    private let metadata = CrashReportMetadata(applicationVersion: "13.2", buildVersion: "1", osVersion: "iOS 27.2", deviceType: "iPhone", architecture: "arm64e")

    private let fixture = Data("""
    {"callStackTree": {"callStackPerThread": false, "callStacks": [{"threadAttributed": true, "callStackRootFrames": [{"binaryName": "Espresso", "address": 4096, "offsetIntoBinaryTextSegment": 100, "sampleCount": 1, "binaryUUID": "00000000-0000-0000-0000-000000000000"}]}]}}
    """.utf8)

    func testMemoryExceptionAppearsInTheCrashList() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CrashReportStore(directory: directory)
        let input = try MemoryExceptionReport.input(encodedDiagnostic: fixture, metadata: metadata)
        let now = Date()
        try store.importDiagnostics([input], intervalStart: now, intervalEnd: now)
        let reports = try store.reports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(reports[0].text.contains("Exception: \(MemoryExceptionReport.exceptionTitle)"))
        XCTAssertTrue(reports[0].text.contains("Espresso"))
    }

    func testNonObjectJSONIsRejected() {
        XCTAssertThrowsError(try MemoryExceptionReport.input(encodedDiagnostic: Data("[1]".utf8), metadata: metadata))
    }

    func testMissingTreeKeyKeepsWholeObject() throws {
        let input = try MemoryExceptionReport.input(encodedDiagnostic: Data("{\"callStacks\": []}".utf8), metadata: metadata)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: input.diagnosticJSON) as? [String: Any])
        XCTAssertNotNil((object["callStackTree"] as? [String: Any])?["callStacks"])
    }
}
