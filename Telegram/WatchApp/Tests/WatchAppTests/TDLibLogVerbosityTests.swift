import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

/// Not in TDShim's generated subset; enough to read the level back through `td_execute`.
private struct GetLogVerbosityLevel: Codable {}

/// Runs the real TDLib: the level must reach it synchronously (a wrong JSON shape would be
/// ignored silently and leave TDLib at its default verbosity 5).
final class TDLibLogVerbosityTests: XCTestCase {
    // Kept for the whole process: TDLibClientManager's deinit waits for its clients to close
    // on a receive loop that has already stopped.
    nonisolated(unsafe) private static let manager = TDLibClientManager()
    nonisolated(unsafe) private static let client = manager.createClient { _, _ in }

    private func currentLevel() throws -> Int? {
        let client = Self.client
        let result = try client.execute(query: DTO(GetLogVerbosityLevel(), encoder: client.encoder))
        return result?["verbosity_level"] as? Int
    }

    func testSetLogVerbosityAppliesSynchronously() throws {
        try TDClient.setLogVerbosity(2, client: Self.client)
        XCTAssertEqual(try currentLevel(), 2)
        try TDClient.setLogVerbosity(0, client: Self.client)
        XCTAssertEqual(try currentLevel(), 0)
    }
}
