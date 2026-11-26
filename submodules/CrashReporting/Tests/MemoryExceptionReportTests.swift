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

    /// The iOS 27 `MemoryExceptionDiagnostic` layout (as `JSONEncoder` writes it): threads in `callStackThreads`,
    /// frames in `rootFrames`, and binaries named only through the `binaryInfo` table.
    private let metricManagerFixture = Data("""
    {"callStackTree": {"binaryInfo": [{"name": "Espresso", "uuid": "00000000-0000-0000-0000-00000000000A"}, {"name": "Nanogram", "uuid": "00000000-0000-0000-0000-00000000000B"}], "callStackPerThread": true, "callStackThreads": [{"threadAttributed": false, "rootFrames": [{"address": 8192, "binaryUUID": "00000000-0000-0000-0000-00000000000C", "offsetIntoBinaryTextSegment": 8, "sampleCount": 1, "subFrames": []}]}, {"threadAttributed": true, "rootFrames": [{"address": 4096, "binaryUUID": "00000000-0000-0000-0000-00000000000A", "offsetIntoBinaryTextSegment": 100, "sampleCount": 1, "subFrames": [{"address": 4200, "binaryUUID": "00000000-0000-0000-0000-00000000000B", "offsetIntoBinaryTextSegment": 204, "sampleCount": 1, "subFrames": [{"address": 4300, "binaryUUID": "00000000-0000-0000-0000-00000000000a", "offsetIntoBinaryTextSegment": 304, "sampleCount": 1}]}, {"address": 4400, "binaryUUID": "00000000-0000-0000-0000-00000000000A", "offsetIntoBinaryTextSegment": 404, "sampleCount": 1}]}]}]}}
    """.utf8)

    private func renderedText(_ diagnostic: Data) throws -> String {
        let input = try MemoryExceptionReport.input(encodedDiagnostic: diagnostic, metadata: metadata)
        let now = Date()
        return CrashReport(id: "test", diagnosticJSON: input.diagnosticJSON, metadata: metadata, intervalStart: now, intervalEnd: now, receivedAt: now, wasPresented: false).text
    }

    func testMetricManagerLayoutShowsTheStacks() throws {
        let text = try renderedText(metricManagerFixture)
        XCTAssertTrue(text.contains("Stack 0\n"))
        XCTAssertTrue(text.contains("Stack 1 (crashed)"))
        XCTAssertTrue(text.contains("\nEspresso 0x1000 +100 [00000000-0000-0000-0000-00000000000A]"))
        XCTAssertTrue(text.contains("\n  Nanogram 0x1068 +204 [00000000-0000-0000-0000-00000000000B]"))
        // binaryInfo and frame UUIDs are matched regardless of case.
        XCTAssertTrue(text.contains("\n    Espresso 0x10cc +304 [00000000-0000-0000-0000-00000000000a]"))
    }

    func testMetricManagerLayoutKeepsFrameOrder() throws {
        let text = try renderedText(metricManagerFixture)
        let root = try XCTUnwrap(text.range(of: "Espresso 0x1000 +100"))
        let child = try XCTUnwrap(text.range(of: "Nanogram 0x1068 +204"))
        let grandchild = try XCTUnwrap(text.range(of: "Espresso 0x10cc +304"))
        let secondChild = try XCTUnwrap(text.range(of: "  Espresso 0x1130 +404"))
        XCTAssertTrue(root.upperBound <= child.lowerBound)
        XCTAssertTrue(child.upperBound <= grandchild.lowerBound)
        XCTAssertTrue(grandchild.upperBound <= secondChild.lowerBound)
    }

    func testMetricManagerFrameMissingFromBinaryInfoIsUnknown() throws {
        let text = try renderedText(metricManagerFixture)
        XCTAssertTrue(text.contains("\nUnknown binary 0x2000 +8 [00000000-0000-0000-0000-00000000000C]"))
    }

    func testCrashLayoutTreeIsKeptAsIs() throws {
        let input = try MemoryExceptionReport.input(encodedDiagnostic: fixture, metadata: metadata)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: input.diagnosticJSON) as? [String: Any])
        let tree = try XCTUnwrap(object["callStackTree"] as? [String: Any])
        XCTAssertEqual(tree["callStackPerThread"] as? Bool, false)
        XCTAssertNil(tree["callStackThreads"])
        XCTAssertTrue(try renderedText(fixture).contains("Stack 0 (crashed)\nEspresso 0x1000 +100"))
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
