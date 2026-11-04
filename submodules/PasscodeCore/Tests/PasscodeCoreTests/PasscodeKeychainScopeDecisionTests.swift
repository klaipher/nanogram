#if os(macOS)
import XCTest
import Security
@testable import PasscodeCore

final class PasscodeKeychainScopeDecisionTests: XCTestCase {
    private final class FakeKeychain {
        var unlocked = true
        var items: [String: PasscodeKeychainScope.Read] = [:]
        var listStatus: OSStatus = errSecSuccess
        var addStatuses: [String: OSStatus] = [:]
        var reads: [String] = []
        var listings = 0
        var added: [String] = []

        static func key(_ service: String, _ account: String) -> String {
            return service + "|" + account
        }

        func set(_ read: PasscodeKeychainScope.Read, _ service: String, _ account: String) {
            self.items[Self.key(service, account)] = read
        }

        var keychain: PasscodeKeychainScope.Keychain {
            return PasscodeKeychainScope.Keychain(isUnlocked: {
                return self.unlocked
            }, read: { service, account in
                self.reads.append(Self.key(service, account))
                return self.items[Self.key(service, account)] ?? .absent
            }, listGenericPasswords: {
                self.listings += 1
                return (self.listStatus, self.items.keys.sorted().map { key in
                    let parts = key.components(separatedBy: "|")
                    return (parts[0], parts[1])
                })
            }, add: { data, service, account in
                let key = Self.key(service, account)
                if let status = self.addStatuses[key] {
                    return status
                }
                if self.items[key] != nil {
                    return errSecDuplicateItem
                }
                self.items[key] = .found(data)
                self.added.append(key)
                return errSecSuccess
            })
        }
    }

    private let passcode = "passcode"
    private let prefixes = ["wallet.descriptor.", "wallet.envelope.", "wallet.journal."]
    private var environment: PasscodeEnvironment!
    private var fake: FakeKeychain!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.environment = PasscodeEnvironment()
        try self.environment.configure(PasscodeConfiguration(appGroupIdentifier: "6N38VWS5BX.org.telegram.tests", processRole: .mainApp, keychainScope: "debug"), privateAccessGroup: { "6N38VWS5BX.org.telegram.tests" })
        self.fake = FakeKeychain()
    }

    private func scoped(_ service: String, scope: String = "debug") -> String {
        return "org.telegram.scoped." + scope + "/" + service
    }

    private func releaseEnvironment(prefix: String = "stable", isAppStoreEdition: Bool = false) throws -> PasscodeEnvironment {
        let environment = PasscodeEnvironment()
        try environment.configure(PasscodeConfiguration(appGroupIdentifier: "YGTMYL879P.org.klaipher.Nanogram", processRole: .mainApp, keychainScope: PasscodeKeychainScope.channelScope(prefix: prefix, isAppStoreEdition: isAppStoreEdition)), privateAccessGroup: { "YGTMYL879P.org.klaipher.Nanogram" })
        return environment
    }

    private func migrateRelease(environment: PasscodeEnvironment, belongsToThisApp: Bool = true) -> PasscodeKeychainScope.Migration {
        return PasscodeKeychainScope.migrateLegacyItems(passcodeService: self.passcode, walletServicePrefixes: self.prefixes, legacyItemsBelongToThisApp: belongsToThisApp, environment: environment, keychain: self.fake.keychain)
    }

    private func key(_ service: String, _ account: String) -> String {
        return FakeKeychain.key(service, account)
    }

    private func migrate() -> PasscodeKeychainScope.Migration {
        return PasscodeKeychainScope.migrateLegacyItems(passcodeService: self.passcode, walletServicePrefixes: self.prefixes, legacyItemsBelongToThisApp: true, environment: self.environment, keychain: self.fake.keychain)
    }

    private func addCredentialSet() {
        self.fake.set(.found(Data("credential".utf8)), self.passcode, "credential")
        self.fake.set(.found(Data("device".utf8)), self.passcode, "device")
    }

    func testWithoutAScopeNothingIsRead() throws {
        let environment = PasscodeEnvironment()
        try environment.configure(PasscodeConfiguration(appGroupIdentifier: "6N38VWS5BX.org.telegram.tests", processRole: .mainApp), privateAccessGroup: { "6N38VWS5BX.org.telegram.tests" })
        self.addCredentialSet()
        XCTAssertEqual(PasscodeKeychainScope.migrateLegacyItems(passcodeService: self.passcode, walletServicePrefixes: self.prefixes, legacyItemsBelongToThisApp: true, environment: environment, keychain: self.fake.keychain), .nothingToMigrate)
        XCTAssertEqual(self.fake.reads, [])
        XCTAssertEqual(self.fake.added, [])
    }

    func testALockedKeychainStopsBeforeReading() {
        self.addCredentialSet()
        self.fake.unlocked = false
        XCTAssertEqual(self.migrate(), .keychainLocked)
        XCTAssertEqual(self.fake.reads, [])
        XCTAssertEqual(self.fake.added, [])
    }

    func testTheUnscopedCredentialSetDecidesWhetherToCopy() {
        let found = PasscodeKeychainScope.Read.found(Data("value".utf8))
        let cases: [(PasscodeKeychainScope.Read, PasscodeKeychainScope.Read, PasscodeKeychainScope.Migration)] = [
            (.locked, found, .keychainLocked),
            (found, .locked, .keychainLocked),
            (.locked, .failed(-1), .keychainLocked),
            (.failed(-1), found, .failed(-1)),
            (found, .failed(-2), .failed(-2)),
            (.notReadable, found, .nothingToMigrate),
            (found, .notReadable, .nothingToMigrate),
            (found, .absent, .nothingToMigrate),
            (.absent, found, .nothingToMigrate),
            (.absent, .absent, .nothingToMigrate)
        ]
        for (credential, device, expected) in cases {
            self.fake = FakeKeychain()
            self.fake.set(credential, self.passcode, "credential")
            self.fake.set(device, self.passcode, "device")
            self.fake.set(.found(Data("descriptor".utf8)), "wallet.descriptor.ns", "wallet")
            XCTAssertEqual(self.migrate(), expected, "\(credential), \(device)")
            XCTAssertEqual(self.fake.added, [], "\(credential), \(device)")
        }
    }

    func testTheScopedCredentialSetDecidesWhetherToCopy() {
        let cases: [(PasscodeKeychainScope.Read, PasscodeKeychainScope.Migration)] = [
            (.notReadable, .nothingToMigrate),
            (.locked, .keychainLocked),
            (.failed(-3), .failed(-3)),
            (.found(Data("other".utf8)), .nothingToMigrate)
        ]
        for account in ["credential", "device"] {
            for (scoped, expected) in cases {
                self.fake = FakeKeychain()
                self.addCredentialSet()
                self.fake.set(.found(Data("descriptor".utf8)), "wallet.descriptor.ns", "wallet")
                self.fake.set(scoped, self.scoped(self.passcode), account)
                XCTAssertEqual(self.migrate(), expected, "\(account): \(scoped)")
                XCTAssertEqual(self.fake.added, [], "\(account): \(scoped)")
            }
        }
    }

    func testAMatchingScopedCredentialSetResumesTheCopy() {
        self.addCredentialSet()
        self.fake.set(.found(Data("credential".utf8)), self.scoped(self.passcode), "credential")
        self.fake.set(.found(Data("descriptor".utf8)), "wallet.descriptor.ns", "wallet")
        XCTAssertEqual(self.migrate(), .migrated(2))
        XCTAssertEqual(self.fake.added, [self.key(self.scoped("wallet.descriptor.ns"), "wallet"), self.key(self.scoped(self.passcode), "device")])
    }

    func testAWalletIsCopiedWholeOrNotAtAll() {
        self.addCredentialSet()
        self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
        self.fake.set(.notReadable, "wallet.envelope.a", "secret")
        self.fake.set(.found(Data("a".utf8)), "wallet.journal.a", "journal")
        self.fake.set(.found(Data("b".utf8)), "wallet.descriptor.b", "wallet")
        self.fake.set(.found(Data("b".utf8)), "wallet.envelope.b", "secret")
        XCTAssertEqual(self.migrate(), .migrated(4))
        XCTAssertEqual(self.fake.added, [
            self.key(self.scoped("wallet.descriptor.b"), "wallet"),
            self.key(self.scoped("wallet.envelope.b"), "secret"),
            self.key(self.scoped(self.passcode), "device"),
            self.key(self.scoped(self.passcode), "credential")
        ])
        XCTAssertFalse(self.fake.reads.contains(self.key("wallet.journal.a", "journal")))
    }

    func testALockOrFailureWhileReadingWalletsCopiesNothing() {
        let cases: [(PasscodeKeychainScope.Read, PasscodeKeychainScope.Migration)] = [
            (.locked, .keychainLocked),
            (.failed(-4), .failed(-4))
        ]
        for (read, expected) in cases {
            self.fake = FakeKeychain()
            self.addCredentialSet()
            self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
            self.fake.set(read, "wallet.descriptor.b", "wallet")
            XCTAssertEqual(self.migrate(), expected, "\(read)")
            XCTAssertEqual(self.fake.added, [], "\(read)")
        }
    }

    func testAListingFailureCopiesNothing() {
        self.addCredentialSet()
        self.fake.listStatus = errSecIO
        XCTAssertEqual(self.migrate(), .failed(errSecIO))
        XCTAssertEqual(self.fake.added, [])
    }

    func testAFailedCopyLeavesTheCredentialForTheNextRun() {
        for failing in [self.key(self.scoped("wallet.descriptor.a"), "wallet"), self.key(self.scoped(self.passcode), "device")] {
            self.fake = FakeKeychain()
            self.addCredentialSet()
            self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
            self.fake.addStatuses[failing] = errSecIO
            XCTAssertEqual(self.migrate(), .failed(errSecIO), failing)
            XCTAssertNil(self.fake.items[self.key(self.scoped(self.passcode), "credential")], failing)
        }
    }

    func testOnlyUnscopedItemsUnderTheWalletPrefixesAreCopied() {
        self.addCredentialSet()
        self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
        self.fake.set(.found(Data("stale".utf8)), "wallet.metadata.a", "wallet")
        self.fake.set(.found(Data("other".utf8)), "other.service", "wallet")
        self.fake.set(.found(Data("scoped".utf8)), self.scoped("wallet.descriptor.b"), "wallet")
        XCTAssertEqual(self.migrate(), .migrated(3))
        XCTAssertEqual(self.fake.added, [
            self.key(self.scoped("wallet.descriptor.a"), "wallet"),
            self.key(self.scoped(self.passcode), "device"),
            self.key(self.scoped(self.passcode), "credential")
        ])
    }

    func testAWalletTheScopeAlreadyHoldsIsNotMixedIn() {
        let cases: [(String, PasscodeKeychainScope.Read)] = [
            ("wallet.descriptor.a", .found(Data("watch-only".utf8))),
            ("wallet.descriptor.a", .notReadable),
            ("wallet.journal.a", .found(Data("own".utf8)))
        ]
        for (service, scoped) in cases {
            self.fake = FakeKeychain()
            self.addCredentialSet()
            self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
            self.fake.set(.found(Data("a".utf8)), "wallet.envelope.a", "secret")
            self.fake.set(.found(Data("b".utf8)), "wallet.descriptor.b", "wallet")
            self.fake.set(scoped, self.scoped(service), "wallet")
            XCTAssertEqual(self.migrate(), .migrated(3), "\(service): \(scoped)")
            XCTAssertEqual(self.fake.added, [
                self.key(self.scoped("wallet.descriptor.b"), "wallet"),
                self.key(self.scoped(self.passcode), "device"),
                self.key(self.scoped(self.passcode), "credential")
            ], "\(service): \(scoped)")
        }
    }

    func testALockOrFailureWhileReadingTheScopeCopiesNothing() {
        let cases: [(PasscodeKeychainScope.Read, PasscodeKeychainScope.Migration)] = [
            (.locked, .keychainLocked),
            (.failed(-5), .failed(-5))
        ]
        for (read, expected) in cases {
            self.fake = FakeKeychain()
            self.addCredentialSet()
            self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
            self.fake.set(.found(Data("b".utf8)), "wallet.descriptor.b", "wallet")
            self.fake.set(read, self.scoped("wallet.descriptor.b"), "wallet")
            XCTAssertEqual(self.migrate(), expected, "\(read)")
            XCTAssertEqual(self.fake.added, [], "\(read)")
        }
    }

    func testIdenticalScopedCopiesResumeTheWallet() {
        self.addCredentialSet()
        self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
        self.fake.set(.found(Data("s".utf8)), "wallet.envelope.a", "secret")
        self.fake.set(.found(Data("s".utf8)), self.scoped("wallet.envelope.a"), "secret")
        XCTAssertEqual(self.migrate(), .migrated(3))
        XCTAssertEqual(self.fake.added, [
            self.key(self.scoped("wallet.descriptor.a"), "wallet"),
            self.key(self.scoped(self.passcode), "device"),
            self.key(self.scoped(self.passcode), "credential")
        ])
    }

    func testWalletItemsAreCopiedInPrefixOrder() {
        self.addCredentialSet()
        self.fake.set(.found(Data("d".utf8)), "wallet.descriptor.a", "wallet")
        self.fake.set(.found(Data("e".utf8)), "wallet.envelope.a", "secret")
        self.fake.set(.found(Data("j".utf8)), "wallet.journal.a", "journal")
        let migration = PasscodeKeychainScope.migrateLegacyItems(passcodeService: self.passcode, walletServicePrefixes: ["wallet.envelope.", "wallet.journal.", "wallet.descriptor."], legacyItemsBelongToThisApp: true, environment: self.environment, keychain: self.fake.keychain)
        XCTAssertEqual(migration, .migrated(5))
        XCTAssertEqual(self.fake.added, [
            self.key(self.scoped("wallet.envelope.a"), "secret"),
            self.key(self.scoped("wallet.journal.a"), "journal"),
            self.key(self.scoped("wallet.descriptor.a"), "wallet"),
            self.key(self.scoped(self.passcode), "device"),
            self.key(self.scoped(self.passcode), "credential")
        ])
    }

    func testChannelScopeKeepsDebugAndGivesEachReleaseChannelAndEditionItsOwnScope() {
        XCTAssertEqual(PasscodeKeychainScope.channelScope(prefix: "debug", isAppStoreEdition: false), "debug")
        XCTAssertEqual(PasscodeKeychainScope.channelScope(prefix: "debug", isAppStoreEdition: true), "debug")
        XCTAssertNil(PasscodeKeychainScope.channelScope(prefix: "", isAppStoreEdition: false))
        XCTAssertNil(PasscodeKeychainScope.channelScope(prefix: "", isAppStoreEdition: true))
        XCTAssertEqual(PasscodeKeychainScope.channelScope(prefix: "stable", isAppStoreEdition: false), "nanogram.stable")
        XCTAssertEqual(PasscodeKeychainScope.channelScope(prefix: "stable", isAppStoreEdition: true), "nanogram.stable.mas")
        var release: [String?] = []
        for prefix in ["stable", "appstore", "beta"] {
            for isAppStoreEdition in [false, true] {
                release.append(PasscodeKeychainScope.channelScope(prefix: prefix, isAppStoreEdition: isAppStoreEdition))
            }
        }
        for scope in release {
            XCTAssertTrue(scope?.hasPrefix("nanogram.") == true, "\(String(describing: scope))")
        }
        XCTAssertEqual(Set(release.compactMap { $0 }).count, 6)
    }

    func testEachScopeHasItsOwnMarkerAndDebugKeepsItsExistingOne() {
        XCTAssertEqual(PasscodeKeychainScope.migrationMarkerName(scope: "debug"), "keychain-scope-v1")
        XCTAssertEqual(PasscodeKeychainScope.migrationMarkerName(scope: "nanogram.stable"), "keychain-scope-v1.nanogram.stable")
        XCTAssertEqual(PasscodeKeychainScope.migrationMarkerName(scope: "nanogram.stable.mas"), "keychain-scope-v1.nanogram.stable.mas")
    }

    func testAReleaseBuildNamesNothingAnUnscopedFilterMatches() throws {
        for isAppStoreEdition in [false, true] {
            let environment = try self.releaseEnvironment(isAppStoreEdition: isAppStoreEdition)
            let passcode = PasscodeKeychainScope.service(PasscodeKeychainScope.legacyPasscodeService, environment: environment)
            XCTAssertEqual(passcode, isAppStoreEdition ? "org.telegram.scoped.nanogram.stable.mas/org.telegram.passcode.v1" : "org.telegram.scoped.nanogram.stable/org.telegram.passcode.v1")
            let wallet = PasscodeKeychainScope.service("org.telegram.ton-wallet.vault.v1.envelope.ns", environment: environment)
            let miniApp = PasscodeKeychainScope.service("TMASecureStorage", environment: environment)
            let biometry = PasscodeKeychainScope.service("TelegramMiniApp", environment: environment)
            for service in [passcode, wallet, miniApp, biometry] {
                XCTAssertFalse(service.hasPrefix("org.telegram.ton-wallet."), service)
                XCTAssertFalse(service.hasPrefix(PasscodeKeychainScope.legacyPasscodeService), service)
                XCTAssertNotEqual(service, "TMASecureStorage")
                XCTAssertNotEqual(service, "TelegramMiniApp")
            }
            XCTAssertTrue(PasscodeKeychainScope.itemGroups([(service: wallet, account: "secret")], servicePrefixes: ["org.telegram.ton-wallet.vault.v1.envelope.", "org.telegram.ton-wallet."]).isEmpty)
        }
    }

    func testABulkWalletRemovalSelectsOnlyThisScopesItems() throws {
        let items: [(service: String, account: String)] = [
            ("org.telegram.ton-wallet.vault.v1.envelope.telegram.production.1", "secret"),
            ("org.telegram.ton-wallet.engine.v2.descriptor.telegram.production.1", "wallet"),
            ("org.telegram.scoped.debug/org.telegram.ton-wallet.engine.v2.descriptor.telegram.production.1", "wallet"),
            ("org.telegram.scoped.nanogram.stable.mas/org.telegram.ton-wallet.vault.v1.envelope.telegram.production.1", "secret"),
            ("org.telegram.scoped.nanogram.stable/org.telegram.ton-wallet.vault.v1.envelope.telegram.production.1", "secret"),
            ("org.telegram.scoped.nanogram.stable/org.telegram.passcode.v1", "credential"),
            ("org.telegram.passcode.v1", "credential")
        ]
        let direct = PasscodeKeychainScope.scopedItems(items, servicePrefix: "org.telegram.ton-wallet.", environment: try self.releaseEnvironment())
        XCTAssertEqual(direct.map { $0.service + "|" + $0.account }, ["org.telegram.scoped.nanogram.stable/org.telegram.ton-wallet.vault.v1.envelope.telegram.production.1|secret"])
        let appStore = PasscodeKeychainScope.scopedItems(items, servicePrefix: "org.telegram.ton-wallet.", environment: try self.releaseEnvironment(isAppStoreEdition: true))
        XCTAssertEqual(appStore.map { $0.service + "|" + $0.account }, ["org.telegram.scoped.nanogram.stable.mas/org.telegram.ton-wallet.vault.v1.envelope.telegram.production.1|secret"])
    }

    func testWithoutEvidenceFromThisAppsOwnDataNothingIsReadOrCopied() throws {
        for isAppStoreEdition in [false, true] {
            let environment = try self.releaseEnvironment(isAppStoreEdition: isAppStoreEdition)
            self.fake = FakeKeychain()
            self.addCredentialSet()
            self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
            XCTAssertEqual(self.migrateRelease(environment: environment, belongsToThisApp: false), .nothingToMigrate)
            XCTAssertEqual(self.fake.reads, [])
            XCTAssertEqual(self.fake.listings, 0)
            XCTAssertEqual(self.fake.added, [])
        }
    }

    func testOnlyThisAppsOwnManagedFlagMakesReleaseItemsItsOwn() {
        XCTAssertTrue(PasscodeKeychainScope.legacyItemsBelongToThisApp(scope: "nanogram.stable", unscopedCredentialManaged: true))
        XCTAssertFalse(PasscodeKeychainScope.legacyItemsBelongToThisApp(scope: "nanogram.stable", unscopedCredentialManaged: false))
        XCTAssertFalse(PasscodeKeychainScope.legacyItemsBelongToThisApp(scope: "nanogram.stable.mas", unscopedCredentialManaged: false))
        XCTAssertTrue(PasscodeKeychainScope.legacyItemsBelongToThisApp(scope: "debug", unscopedCredentialManaged: false))
    }

    func testAnUnscopedItemThisAppCannotReadWithoutAPromptIsNotCopied() throws {
        let environment = try self.releaseEnvironment()
        for account in ["credential", "device"] {
            self.fake = FakeKeychain()
            self.addCredentialSet()
            self.fake.set(.notReadable, self.passcode, account)
            self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
            XCTAssertEqual(self.migrateRelease(environment: environment), .nothingToMigrate, account)
            XCTAssertEqual(self.fake.added, [], account)
        }
    }

    func testOwnedItemsAreCopiedIntoTheReleaseScopeAndTheOriginalsStay() throws {
        for isAppStoreEdition in [false, true] {
            let environment = try self.releaseEnvironment(isAppStoreEdition: isAppStoreEdition)
            let scope = isAppStoreEdition ? "nanogram.stable.mas" : "nanogram.stable"
            self.fake = FakeKeychain()
            self.addCredentialSet()
            self.fake.set(.found(Data("a".utf8)), "wallet.descriptor.a", "wallet")
            self.fake.set(.found(Data("s".utf8)), "wallet.envelope.a", "secret")
            self.fake.set(.notReadable, "wallet.descriptor.b", "wallet")
            let before = self.fake.items
            XCTAssertEqual(self.migrateRelease(environment: environment), .migrated(4))
            XCTAssertEqual(self.fake.added, [
                self.key(self.scoped("wallet.descriptor.a", scope: scope), "wallet"),
                self.key(self.scoped("wallet.envelope.a", scope: scope), "secret"),
                self.key(self.scoped(self.passcode, scope: scope), "device"),
                self.key(self.scoped(self.passcode, scope: scope), "credential")
            ])
            for (key, value) in before {
                XCTAssertEqual(self.fake.items[key], value, key)
            }
            XCTAssertEqual(self.fake.items.count, before.count + 4)
        }
    }

    private final class MarkerFolder {
        var existing: Set<String> = []
        var written: [String] = []
        var migrations: [Bool] = []
        var flagReads = 0
    }

    private func migrateOnce(environment: PasscodeEnvironment, folder: MarkerFolder, isFreshInstallation: Bool = false, managed: Bool = true, result: PasscodeKeychainScope.Migration) -> PasscodeKeychainScope.MigrationStep {
        return PasscodeKeychainScope.migrateOnce(environment: environment, dataDirectory: "/data/stable", isFreshInstallation: isFreshInstallation, markerExists: { folder.existing.contains($0) }, writeMarker: { folder.written.append($0); folder.existing.insert($0) }, migrate: { belongs in
            folder.migrations.append(belongs)
            return result
        }, unscopedCredentialManaged: {
            folder.flagReads += 1
            return managed
        })
    }

    func testTheMarkerIsWrittenOnlyAfterADecidedOutcome() throws {
        let environment = try self.releaseEnvironment()
        let marker = "/data/stable/keychain-scope-v1.nanogram.stable"
        let cases: [(PasscodeKeychainScope.Migration, PasscodeKeychainScope.MigrationStep, Bool)] = [
            (.migrated(3), .finished(.migrated(3)), true),
            (.nothingToMigrate, .finished(.nothingToMigrate), true),
            (.keychainLocked, .retryNextLaunch(.keychainLocked), false),
            (.failed(errSecIO), .retryNextLaunch(.failed(errSecIO)), false)
        ]
        for (result, expected, writesMarker) in cases {
            let folder = MarkerFolder()
            XCTAssertEqual(self.migrateOnce(environment: environment, folder: folder, result: result), expected, "\(result)")
            XCTAssertEqual(folder.written, writesMarker ? [marker] : [], "\(result)")
            XCTAssertEqual(folder.migrations, [true], "\(result)")
        }
    }

    func testARetriedCopyRunsAgainOnTheNextLaunchAndAFinishedOneNever() throws {
        let environment = try self.releaseEnvironment()
        let folder = MarkerFolder()
        XCTAssertEqual(self.migrateOnce(environment: environment, folder: folder, result: .failed(errSecIO)), .retryNextLaunch(.failed(errSecIO)))
        XCTAssertEqual(self.migrateOnce(environment: environment, folder: folder, result: .migrated(2)), .finished(.migrated(2)))
        XCTAssertEqual(self.migrateOnce(environment: environment, folder: folder, result: .migrated(2)), .notNeeded)
        XCTAssertEqual(folder.migrations.count, 2)
    }

    func testEachEditionMigratesOnceUnderItsOwnMarker() throws {
        let folder = MarkerFolder()
        XCTAssertEqual(self.migrateOnce(environment: try self.releaseEnvironment(), folder: folder, result: .migrated(2)), .finished(.migrated(2)))
        XCTAssertEqual(self.migrateOnce(environment: try self.releaseEnvironment(isAppStoreEdition: true), folder: folder, result: .nothingToMigrate), .finished(.nothingToMigrate))
        XCTAssertEqual(folder.written, ["/data/stable/keychain-scope-v1.nanogram.stable", "/data/stable/keychain-scope-v1.nanogram.stable.mas"])
        XCTAssertEqual(folder.migrations.count, 2)
    }

    func testDebugKeepsItsExistingMarkerAndNeedsNoFlag() {
        let folder = MarkerFolder()
        folder.existing = ["/data/stable/keychain-scope-v1"]
        XCTAssertEqual(self.migrateOnce(environment: self.environment, folder: folder, managed: false, result: .migrated(1)), .notNeeded)
        XCTAssertEqual(folder.migrations, [])
        let fresh = MarkerFolder()
        XCTAssertEqual(self.migrateOnce(environment: self.environment, folder: fresh, managed: false, result: .migrated(1)), .finished(.migrated(1)))
        XCTAssertEqual(fresh.migrations, [true])
        XCTAssertEqual(fresh.written, ["/data/stable/keychain-scope-v1"])
    }

    func testTheReleaseCopyFollowsThisAppsManagedFlag() throws {
        let environment = try self.releaseEnvironment()
        for managed in [false, true] {
            let folder = MarkerFolder()
            _ = self.migrateOnce(environment: environment, folder: folder, managed: managed, result: .nothingToMigrate)
            XCTAssertEqual(folder.migrations, [managed])
        }
    }

    func testAFreshInstallationOrAnUnscopedBuildCopiesNothing() throws {
        let folder = MarkerFolder()
        XCTAssertEqual(self.migrateOnce(environment: try self.releaseEnvironment(), folder: folder, isFreshInstallation: true, result: .migrated(1)), .finished(nil))
        XCTAssertEqual(folder.migrations, [])
        XCTAssertEqual(folder.flagReads, 0)
        XCTAssertEqual(folder.written, ["/data/stable/keychain-scope-v1.nanogram.stable"])
        let unscoped = PasscodeEnvironment()
        try unscoped.configure(PasscodeConfiguration(appGroupIdentifier: "6N38VWS5BX.org.telegram.tests", processRole: .mainApp), privateAccessGroup: { "6N38VWS5BX.org.telegram.tests" })
        let none = MarkerFolder()
        XCTAssertEqual(self.migrateOnce(environment: unscoped, folder: none, result: .migrated(1)), .notNeeded)
        XCTAssertEqual(none.migrations, [])
        XCTAssertEqual(none.written, [])
    }

    func testOnlyAFinishedCopyCarriesTheFlagOverAndOnlyARetryRequiresTheCredential() {
        let steps: [(PasscodeKeychainScope.MigrationStep, Bool, Bool)] = [
            (.notNeeded, false, false),
            (.finished(nil), false, false),
            (.finished(.nothingToMigrate), false, false),
            (.finished(.migrated(0)), true, false),
            (.finished(.migrated(4)), true, false),
            (.retryNextLaunch(.keychainLocked), false, true),
            (.retryNextLaunch(.failed(errSecIO)), false, true)
        ]
        for (step, carries, requires) in steps {
            XCTAssertEqual(step.carriesManagedFlagOver, carries, "\(step)")
            XCTAssertEqual(step.requiresExistingCredential, requires, "\(step)")
        }
    }

    func testItemGroupsIgnoreScopedNames() {
        let groups = PasscodeKeychainScope.itemGroups([
            (service: "org.telegram.scoped.debug/org.telegram.x.a", account: "scoped"),
            (service: "org.telegram.x.a", account: "wallet"),
            (service: "org.telegram.y", account: "other")
        ], servicePrefixes: ["org.telegram.x.", "org.telegram."])
        XCTAssertEqual(groups.map { group in group.name + ": " + group.items.map { $0.service + "|" + $0.account }.joined(separator: ",") }, [
            "a: org.telegram.x.a|wallet",
            "y: org.telegram.y|other"
        ])
    }

    func testReadStatusesAreClassified() {
        let data = Data("value".utf8) as CFData
        XCTAssertEqual(PasscodeKeychainScope.classify(errSecSuccess, result: data, isUnlocked: { true }), .found(Data("value".utf8)))
        XCTAssertEqual(PasscodeKeychainScope.classify(errSecSuccess, result: nil, isUnlocked: { true }), .failed(errSecDecode))
        XCTAssertEqual(PasscodeKeychainScope.classify(errSecSuccess, result: "value" as CFString, isUnlocked: { true }), .failed(errSecDecode))
        XCTAssertEqual(PasscodeKeychainScope.classify(errSecItemNotFound, result: nil, isUnlocked: { true }), .absent)
        for status in [errSecAuthFailed, errSecInteractionNotAllowed] {
            XCTAssertEqual(PasscodeKeychainScope.classify(status, result: nil, isUnlocked: { true }), .notReadable, "\(status)")
            XCTAssertEqual(PasscodeKeychainScope.classify(status, result: nil, isUnlocked: { false }), .locked, "\(status)")
        }
        XCTAssertEqual(PasscodeKeychainScope.classify(errSecIO, result: nil, isUnlocked: { true }), .failed(errSecIO))
    }
}
#endif
