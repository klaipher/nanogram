import XCTest
@testable import tgwatch_Watch_App

/// The watch's part of the iPhone's "Send Report": its energy numbers, its report files, and the payload size.
final class WatchDiagnosticsTests: XCTestCase {
    private let context = EnergyContext(batteryPercent: 71, power: .unplugged, lowPowerMode: false, thermal: "nominal")

    func testReportHasManifestInfoEnergyAndLog() {
        let payload = WatchReportBuilder.payload(WatchReportInputs(created: Date(timeIntervalSince1970: 0), appVersion: "1.0", buildNumber: "9", bundleId: "x.watchkitapp", osVersion: "watchOS 26.1", modelIdentifier: "Watch7,1", context: context, energyText: "energy", logText: "log line\n", logNote: "note"))
        XCTAssertEqual(payload.files.map(\.name), ["manifest.txt", "info.txt", "energy.txt", "log.txt"])
        XCTAssertTrue(payload.files[0].text.contains("log.txt: note"))
        XCTAssertTrue(payload.files[1].text.contains("Watch7,1"))
        XCTAssertTrue(payload.files[1].text.contains("battery 71%"))
    }

    func testPayloadFitsTheMessageSize() {
        let log = String(repeating: "2026-11-14T10:00:00Z [x] some log line\n", count: 40_000)
        let payload = WatchReportPayload(created: Date(), files: [WatchReportFile(name: "log.txt", text: log)])
        let data = payload.encoded()
        XCTAssertNotNil(data)
        XCTAssertLessThanOrEqual(data?.count ?? Int.max, WatchReportMessage.maximumBytes)
    }
}
