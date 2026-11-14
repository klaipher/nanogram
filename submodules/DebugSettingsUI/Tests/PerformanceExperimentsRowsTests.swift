import XCTest
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
@testable import DebugSettingsUI

/// The "Performance experiments" section: one switch per dark experiment, the device chip and the measured numbers,
/// in the main app only (which TestFlight builds are, like every build that has the Debug Settings).
final class PerformanceExperimentsRowsTests: XCTestCase {
    private func entries(isMainApp: Bool, enabled: Set<PerformanceExperiment> = [], identifier: String = "iPhone15,2", summary: [String] = []) -> [DebugControllerEntry] {
        var environment = DebugControllerEntriesEnvironment(isMainApp: isMainApp, hasAccount: false, isDevAccount: false, modernVideoMessagePipelineKilled: false, networkEngineKind: nil, useBetaFeatures: false)
        environment.enabledPerformanceExperiments = enabled
        environment.deviceModelIdentifier = identifier
        environment.performanceExperimentSummary = summary
        return debugControllerEntries(environment: environment, theme: defaultPresentationTheme, loggingSettings: LoggingSettings.defaultSettings, experimentalSettings: .defaultSettings, networkSettings: nil, networkEngineSettings: NetworkEngineSettings.defaultSettings)
    }

    private func sectionEntries(_ all: [DebugControllerEntry]) -> [DebugControllerEntry] {
        let section = DebugControllerEntry.performanceExperimentsHeader(defaultPresentationTheme).section
        return all.filter { $0.section == section }
    }

    func testEveryExperimentHasASwitchThatStartsOff() {
        let rows = self.sectionEntries(self.entries(isMainApp: true))
        XCTAssertEqual(rows.count, 5)
        let switches = rows.compactMap { entry -> (PerformanceExperiment, Bool)? in
            if case let .performanceExperiment(experiment, value) = entry {
                return (experiment, value)
            }
            return nil
        }
        XCTAssertEqual(switches.map { $0.0 }, PerformanceExperiment.allCases)
        XCTAssertEqual(switches.map { $0.1 }, [false, false, false])
    }

    func testSwitchesShowTheStoredState() {
        let rows = self.sectionEntries(self.entries(isMainApp: true, enabled: [.previewHardwareDecode]))
        XCTAssertTrue(rows.contains(.performanceExperiment(.previewHardwareDecode, true)))
        XCTAssertTrue(rows.contains(.performanceExperiment(.softwareDecodeThreads, false)))
    }

    func testSectionIsOrderedHeaderSwitchesInfoAndMainAppOnly() {
        let rows = self.sectionEntries(self.entries(isMainApp: true))
        XCTAssertEqual(rows.map(\.stableId), [160, 161, 162, 163, 164])
        XCTAssertTrue(self.sectionEntries(self.entries(isMainApp: false)).isEmpty)
    }

    func testInfoRowNamesTheDeviceAndCarriesTheNumbers() {
        let rows = self.sectionEntries(self.entries(isMainApp: true, identifier: "iPhone14,7", summary: ["a=off x: no samples"]))
        guard case let .performanceExperimentsInfo(text)? = rows.last else {
            XCTFail("no info row")
            return
        }
        XCTAssertTrue(text.contains("iPhone 14 (A15), iPhone14,7"))
        XCTAssertTrue(text.contains("Force-quit and reopen"))
        XCTAssertTrue(text.hasSuffix("a=off x: no samples"))
    }

    func testDeviceChips() {
        XCTAssertEqual(performanceExperimentsDeviceChip(identifier: "iPhone15,2"), "iPhone 14 Pro (A16), iPhone15,2")
        XCTAssertEqual(performanceExperimentsDeviceChip(identifier: "iPhone14,7"), "iPhone 14 (A15), iPhone14,7")
        XCTAssertEqual(performanceExperimentsDeviceChip(identifier: "iPhone17,1"), "iPhone17,1")
        XCTAssertEqual(performanceExperimentsDeviceChip(identifier: ""), "unknown device")
    }

    func testEveryExperimentHasADescriptionThatSaysItAppliesAfterARelaunch() {
        for experiment in PerformanceExperiment.allCases {
            XCTAssertTrue(performanceExperimentDescription(experiment).contains("relaunch"), experiment.rawValue)
        }
    }
}
