import XCTest
import SwiftSignalKit

final class ExperimentalPerformanceFlagsTests: XCTestCase {
    private func makeDefaults() throws -> UserDefaults {
        let name = "ExperimentalPerformanceFlagsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testEveryExperimentIsOffByDefault() throws {
        let flags = ExperimentalPerformanceFlags(defaults: try makeDefaults())
        for experiment in PerformanceExperiment.allCases {
            XCTAssertFalse(flags.isEnabled(experiment), experiment.rawValue)
        }
    }

    func testStoredValueTurnsOneExperimentOn() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: PerformanceExperiment.softwareDecodeThreads.defaultsKey)
        let flags = ExperimentalPerformanceFlags(defaults: defaults)
        XCTAssertTrue(flags.isEnabled(.softwareDecodeThreads))
        XCTAssertFalse(flags.isEnabled(.previewHardwareDecode))
    }

    func testOverrideWinsAndCanBeCleared() throws {
        let flags = ExperimentalPerformanceFlags(defaults: try makeDefaults())
        flags.setOverride(.previewHardwareDecode, true)
        XCTAssertTrue(flags.isEnabled(.previewHardwareDecode))
        flags.setOverride(.previewHardwareDecode, nil)
        XCTAssertFalse(flags.isEnabled(.previewHardwareDecode))
    }

    func testKeysAreUnique() {
        let keys = PerformanceExperiment.allCases.map { $0.defaultsKey }
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}
