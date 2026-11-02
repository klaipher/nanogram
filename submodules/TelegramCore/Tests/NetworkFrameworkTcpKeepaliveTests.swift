import XCTest
import Network
@testable import TelegramCore

final class NetworkFrameworkTcpKeepaliveTests: XCTestCase {
    // An idle MTProto connection sent a TCP keepalive every 5 s, which keeps the cellular
    // radio from dropping to idle. The connection's viability handler and MTProto's own
    // pings notice a dead connection, so the probes only need to catch silent NAT drops.
    func testIdleConnectionsProbeEvery30sThen10sThreeTimes() {
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
