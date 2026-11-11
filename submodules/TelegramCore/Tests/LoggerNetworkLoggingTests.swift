import XCTest
@testable import TelegramCore

final class LoggerNetworkLoggingTests: XCTestCase {
    func testLoggingToFileOrConsoleAloneDoesNotTurnTheProtocolDumpsOn() {
        XCTAssertFalse(Logger.isNetworkLoggingEnabled(logToFile: true, logToConsole: false, logNetworkDumps: false))
        XCTAssertFalse(Logger.isNetworkLoggingEnabled(logToFile: false, logToConsole: true, logNetworkDumps: false))
        XCTAssertFalse(Logger.isNetworkLoggingEnabled(logToFile: true, logToConsole: true, logNetworkDumps: false))
    }

    func testTheDumpsNeedTheSwitchAndSomewhereToWrite() {
        XCTAssertTrue(Logger.isNetworkLoggingEnabled(logToFile: true, logToConsole: false, logNetworkDumps: true))
        XCTAssertTrue(Logger.isNetworkLoggingEnabled(logToFile: false, logToConsole: true, logNetworkDumps: true))
        XCTAssertFalse(Logger.isNetworkLoggingEnabled(logToFile: false, logToConsole: false, logNetworkDumps: true))
    }

    func testTheSwitchIsOffByDefaultAndKeptByTheUpdaters() {
        XCTAssertFalse(LoggingSettings.defaultSettings.logNetworkDumps)
        let on = LoggingSettings.defaultSettings.withUpdatedLogNetworkDumps(true)
        XCTAssertTrue(on.logNetworkDumps)
        XCTAssertTrue(on.withUpdatedLogToFile(true).logNetworkDumps)
        XCTAssertTrue(on.withUpdatedLogToConsole(true).logNetworkDumps)
        XCTAssertTrue(on.withUpdatedRedactSensitiveData(false).logNetworkDumps)
        XCTAssertNotEqual(on, LoggingSettings.defaultSettings)
    }
}
