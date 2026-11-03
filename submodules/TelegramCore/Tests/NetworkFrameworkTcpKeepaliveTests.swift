import XCTest
import Network
@testable import TelegramCore

final class NetworkFrameworkTcpKeepaliveTests: XCTestCase {
    func testIdleConnectionsProbeEvery30sThen10sThreeTimes() throws {
        guard #available(macOS 14.0, *) else {
            throw XCTSkip("Network.framework transport needs macOS 14")
        }
        let options = NWProtocolTCP.Options()
        configureNetworkFrameworkTcpOptions(options)
        XCTAssertTrue(options.noDelay)
        XCTAssertTrue(options.enableKeepalive)
        XCTAssertEqual(options.keepaliveIdle, 30)
        XCTAssertEqual(options.keepaliveInterval, 10)
        XCTAssertEqual(options.keepaliveCount, 3)
        XCTAssertTrue(options.enableFastOpen)
    }
}
