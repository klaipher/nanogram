import XCTest
@preconcurrency import TDShim
@testable import tgwatch_Watch_App

enum CoreAccountFixtures {
    static func account(id: UUID = UUID(), activeAt seconds: TimeInterval = 0) -> Account {
        Account(
            id: id, useTestDc: false, displayName: nil, phoneNumber: nil, userId: nil,
            createdAt: Date(timeIntervalSince1970: 0), lastActiveAt: Date(timeIntervalSince1970: seconds)
        )
    }
}

/// Builds clients that never reach TDLib: the tests run with placeholder credentials, so
/// `TDClient.start()` stops at the credentials check before creating a TDLib client.
@MainActor
private final class RecordingFactory: TDClientFactory {
    private(set) var made: [UUID] = []
    func make(account: Account, delegate: TDClientLifecycleDelegate) -> TDClient {
        made.append(account.id)
        return TDClient(account: account, makeClient: { _ in
            fatalError("TDLib is not used in these tests")
        }, delegate: delegate)
    }
}

/// Holds every close until `open()`, like TDLib taking its time to reach `closed`.
@MainActor
private final class CloseGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var closed: [UUID] = []
    var closeCount: Int { closed.count }

    func close(_ client: TDClient) async {
        closed.append(client.account.id)
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
final class CoreAccountManagerTests: XCTestCase {

    override func setUp() async throws {
        guard case .failure = validateSecrets(apiId: Secrets.apiId, apiHash: Secrets.apiHash) else {
            throw XCTSkip("needs placeholder credentials (TG_API_ID=0) so no TDLib client starts")
        }
    }

    private func makeManager(
        accounts: [Account], active: UUID?, factory: RecordingFactory, gate: CloseGate
    ) throws -> AccountManager {
        let initial = try JSONEncoder().encode(AccountRegistryState(version: 1, activeAccountId: active, accounts: accounts))
        let registry = AccountRegistry(
            readData: { initial },
            writeData: { _, _ in }
        )
        return AccountManager(
            registry: registry,
            factory: factory,
            environment: [:],
            accountDirectoryRemover: { _ in },
            closeClient: { await gate.close($0) }
        )
    }

    /// A double tap on an account row while the current client is still closing.
    func testOverlappingSwitchesToOneAccountStartOneClient() async throws {
        let a = CoreAccountFixtures.account(activeAt: 2)
        let b = CoreAccountFixtures.account(activeAt: 1)
        let factory = RecordingFactory()
        let gate = CloseGate()
        let manager = try makeManager(accounts: [a, b], active: a.id, factory: factory, gate: gate)
        manager.bootstrap()
        XCTAssertEqual(factory.made, [a.id])

        let first = Task { await manager.switchTo(accountId: b.id) }
        let second = Task { await manager.switchTo(accountId: b.id) }
        for _ in 0..<10 { await Task.yield() }
        gate.open()
        await first.value
        await second.value

        XCTAssertEqual(factory.made, [a.id, b.id], "one client per account")
        XCTAssertEqual(gate.closeCount, 1, "the previous client is closed once")
        XCTAssertEqual(manager.activeAccountId, b.id)
        XCTAssertEqual(manager.activeClient?.account.id, b.id)
    }

    /// Switching to A then B quickly ends on B, with A's client closed rather than dropped.
    func testOverlappingSwitchesToDifferentAccountsCloseEachClient() async throws {
        let a = CoreAccountFixtures.account(activeAt: 3)
        let b = CoreAccountFixtures.account(activeAt: 2)
        let c = CoreAccountFixtures.account(activeAt: 1)
        let factory = RecordingFactory()
        let gate = CloseGate()
        let manager = try makeManager(accounts: [a, b, c], active: a.id, factory: factory, gate: gate)
        manager.bootstrap()

        let first = Task { await manager.switchTo(accountId: b.id) }
        let second = Task { await manager.switchTo(accountId: c.id) }
        for _ in 0..<10 { await Task.yield() }
        gate.open()
        await first.value
        await second.value

        XCTAssertEqual(factory.made, [a.id, b.id, c.id])
        XCTAssertEqual(gate.closed, [a.id, b.id], "b is closed, not dropped")
        XCTAssertEqual(manager.activeClient?.account.id, c.id)
    }

    func testSceneStateReachesClientsStartedLater() async throws {
        let a = CoreAccountFixtures.account(activeAt: 2)
        let b = CoreAccountFixtures.account(activeAt: 1)
        let factory = RecordingFactory()
        let gate = CloseGate()
        gate.open()
        let manager = try makeManager(accounts: [a, b], active: a.id, factory: factory, gate: gate)
        manager.setSceneActive(false)
        manager.bootstrap()
        XCTAssertEqual(manager.activeClient?.isSceneActive, false)

        await manager.switchTo(accountId: b.id)
        XCTAssertEqual(manager.activeClient?.isSceneActive, false)

        manager.setSceneActive(true)
        XCTAssertEqual(manager.activeClient?.isSceneActive, true)
    }
}
