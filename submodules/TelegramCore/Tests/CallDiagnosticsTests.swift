import Foundation
import XCTest
@testable import TelegramCore

final class CallDiagnosticsTests: XCTestCase {
    func testDropLineNamesCallStateReasonAndSite() {
        let line = CallDiagnostics.dropLine(callId: 42, state: "accepting", reason: "disconnect", file: "TelegramCore/CallSessionManager.swift", line: 998)
        XCTAssertEqual(line, "drop call 42 in accepting as disconnect from CallSessionManager.swift:998")
    }

    func testDropLineWithoutCallId() {
        XCTAssertEqual(CallDiagnostics.dropLine(callId: nil, state: "requesting", reason: "hangUp", file: "A.swift", line: 1), "drop call - in requesting as hangUp from A.swift:1")
    }

    func testBuildLine() {
        XCTAssertEqual(CallDiagnostics.buildLine(callId: 7, build: "202611041250"), "call 7 on build 202611041250")
        XCTAssertEqual(CallDiagnostics.buildLine(callId: nil, build: nil), "call - on build ?")
    }

    func testRpcErrorNameKeepsOnlyTheCode() {
        XCTAssertEqual(CallDiagnostics.rpcErrorName(code: 400, description: "CALL_ALREADY_DECLINED"), "rpc 400 CALL_ALREADY_DECLINED")
        XCTAssertEqual(CallDiagnostics.rpcErrorName(code: 420, description: "FLOOD_WAIT_5 extra text"), "rpc 420 FLOOD_WAIT_5")
        XCTAssertEqual(CallDiagnostics.rpcErrorName(code: 500, description: ""), "rpc 500")
    }

    func testDiscardDescription() {
        XCTAssertEqual(CallDiagnostics.discardDescription(reason: "hangup", flags: 4), "reason hangup, flags 0x4")
        XCTAssertEqual(CallDiagnostics.discardDescription(reason: nil, flags: 0), "reason none, flags 0x0")
    }
}
