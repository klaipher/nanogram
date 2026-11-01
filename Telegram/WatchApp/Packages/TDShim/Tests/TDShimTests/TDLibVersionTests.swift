import XCTest
import TDLibFramework
@testable import TDShim

/// The generated models match one TDLib schema. A TDLib build of another version may remove
/// fields the models decode as non-optional, so every message would fail to decode. Bumping
/// past 1.8.64 needs the models regenerated (see Generated/README.md) and this test updated.
final class TDLibVersionTests: XCTestCase {
    func test_linkedTDLib_matchesGeneratedSchemaVersion() throws {
        let request = #"{"@type":"getOption","name":"version"}"#
        let result = try XCTUnwrap(td_execute(request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: result).utf8)) as? [String: Any])
        XCTAssertEqual(json["@type"] as? String, "optionValueString")
        XCTAssertEqual(json["value"] as? String, "1.8.64")
    }
}
