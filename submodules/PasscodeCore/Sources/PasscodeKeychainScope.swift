#if os(macOS)
import Foundation
import Security

/// Keeps a channel's keychain items apart from other apps' and other channels' on macOS. The unscoped names
/// belong to the official Telegram app, which shares the login keychain with Nanogram; every Nanogram channel
/// therefore takes a scope from `channelScope(prefix:isAppStoreEdition:)` and stores its passcode, biometric and
/// wallet items under `org.telegram.scoped.<scope>/<name>`, which no unscoped name filter matches, so it neither
/// prompts for nor resets anyone else's items. The direct and App Store editions are signed differently, so each
/// has its own scope: an item one of them creates is readable by the other only after a prompt.
///
/// `migrateOnce` copies the items 13.1.x left under the unscoped names into the scope once per scope, before
/// anything reads the scope. Whether those items are this app's is decided from this app's own data only (the
/// managed-credential flag in its own defaults, see `legacyItemsBelongToThisApp`), never from an item's access
/// list, which cannot be read without a possible prompt. Every read runs with keychain user interaction
/// disabled, so an item whose access list does not trust this app is skipped instead of prompting. The
/// unscoped items are never changed or deleted.
@available(macOS 10.15, *)
public enum PasscodeKeychainScope {
    public enum Migration: Equatable {
        case migrated(Int)
        case nothingToMigrate
        case keychainLocked
        case failed(OSStatus)
    }

    /// What one launch did about the copy. `finished` writes the scope's marker, so the copy never runs again
    /// for that scope; `retryNextLaunch` leaves it unwritten.
    public enum MigrationStep: Equatable {
        case notNeeded
        case finished(Migration?)
        case retryNextLaunch(Migration)

        /// The scoped credential may be missing until a later launch copies it, so it must not be created anew.
        public var requiresExistingCredential: Bool {
            if case .retryNextLaunch = self {
                return true
            }
            return false
        }

        /// The managed-credential flag describes the copied credential only after a copy.
        public var carriesManagedFlagOver: Bool {
            if case .finished(.migrated?) = self {
                return true
            }
            return false
        }
    }

    enum Read: Equatable {
        case found(Data)
        case absent
        case notReadable
        case locked
        case failed(OSStatus)
    }

    struct Keychain {
        var isUnlocked: () -> Bool
        var read: (_ service: String, _ account: String) -> Read
        var listGenericPasswords: () -> (status: OSStatus, items: [(service: String, account: String)])
        var add: (_ data: Data, _ service: String, _ account: String) -> OSStatus
    }

    public static let legacyPasscodeService = "org.telegram.passcode.v1"

    private static let root = "org.telegram.scoped."
    private static let debugScope = "debug"
    private static let legacyMarkerName = "keychain-scope-v1"
    private static let interactionLock = NSLock()

    static var system: Keychain {
        return Keychain(isUnlocked: isDefaultKeychainUnlocked, read: readWithoutInteraction, listGenericPasswords: listGenericPasswords, add: addIfMissing)
    }

    /// The scope of the channel whose data folder is named `prefix`: Debug keeps its existing `debug` scope, every
    /// other channel gets `nanogram.<prefix>`, and the App Store edition, which shares the direct edition's data
    /// folder but not its signature, gets `nanogram.<prefix>.mas`. An empty prefix has no scope.
    public static func channelScope(prefix: String, isAppStoreEdition: Bool) -> String? {
        if prefix.isEmpty {
            return nil
        }
        if prefix == Self.debugScope {
            return prefix
        }
        return "nanogram." + prefix + (isAppStoreEdition ? ".mas" : "")
    }

    /// The file in the data folder that records a finished copy into `scope`. Debug keeps the name it has used
    /// since its scope was introduced; every other scope has its own, because both editions share a data folder.
    public static func migrationMarkerName(scope: String) -> String {
        if scope == Self.debugScope {
            return Self.legacyMarkerName
        }
        return Self.legacyMarkerName + "." + scope
    }

    /// Whether the unscoped items are this app's, decided from this app's own data: Debug always copied whatever
    /// it could read, and a release channel only when its own defaults record that it set up or adopted the
    /// passcode credential under the unscoped names (`unscopedCredentialManaged`). Official Telegram never writes
    /// this app's defaults.
    public static func legacyItemsBelongToThisApp(scope: String, unscopedCredentialManaged: Bool) -> Bool {
        return scope == Self.debugScope || unscopedCredentialManaged
    }

    public static func service(_ service: String, environment: PasscodeEnvironment = .shared) -> String {
        guard let scope = environment.keychainScope else {
            return service
        }
        return Self.root + scope + "/" + service
    }

    /// The items among `items` whose service starts with `servicePrefix` in this build's scope: the only ones a
    /// bulk removal of that prefix may delete.
    public static func scopedItems(_ items: [(service: String, account: String)], servicePrefix: String, environment: PasscodeEnvironment = .shared) -> [(service: String, account: String)] {
        let prefix = Self.service(servicePrefix, environment: environment)
        return items.filter { $0.service.hasPrefix(prefix) }
    }

    /// Runs the copy into this build's scope once per scope. Without a scope, or once the scope's marker exists in
    /// `dataDirectory`, nothing runs. A fresh installation has nothing to copy and only writes the marker. A copy
    /// that finds the keychain locked or fails leaves the marker unwritten, so the next launch tries again; any
    /// other outcome writes it.
    public static func migrateOnce(environment: PasscodeEnvironment = .shared, dataDirectory: String, isFreshInstallation: Bool, markerExists: (String) -> Bool, writeMarker: (String) -> Void, migrate: (_ legacyItemsBelongToThisApp: Bool) -> Migration, unscopedCredentialManaged: () -> Bool) -> MigrationStep {
        guard let scope = environment.keychainScope else {
            return .notNeeded
        }
        let marker = (dataDirectory as NSString).appendingPathComponent(Self.migrationMarkerName(scope: scope))
        if markerExists(marker) {
            return .notNeeded
        }
        var migration: Migration?
        if !isFreshInstallation {
            let result = migrate(Self.legacyItemsBelongToThisApp(scope: scope, unscopedCredentialManaged: unscopedCredentialManaged()))
            switch result {
            case .keychainLocked, .failed:
                return .retryNextLaunch(result)
            case .migrated, .nothingToMigrate:
                migration = result
            }
        }
        writeMarker(marker)
        return .finished(migration)
    }

    /// Copies the passcode credential, the device secret and the wallet items from the unscoped names into the
    /// scope. Unless `legacyItemsBelongToThisApp`, nothing is read and nothing is copied. Otherwise only items this
    /// build can read without user interaction are copied, so an item whose access list does not trust this app
    /// is skipped and never prompts. The unscoped items are never changed or deleted. Wallet items are grouped by
    /// the name that follows their service prefix. A group is copied only when all of its items are readable and
    /// the scope holds nothing under that name but identical copies, so a wallet is copied whole or not at all and
    /// is never mixed with the scope's own items; within a group, items are copied in the order of
    /// `walletServicePrefixes`. Wallet items are copied first and the credential last, and only together with the
    /// device secret that protects them, so an interrupted copy resumes on the next run; a scope whose credential
    /// differs from the unscoped one is left as it is. Existing scoped items are never replaced, and the attempts
    /// counter is not copied. Keychain user interaction is disabled for the whole process during each read.
    public static func migrateLegacyItems(passcodeService: String = Self.legacyPasscodeService, walletServicePrefixes: [String], legacyItemsBelongToThisApp: Bool, environment: PasscodeEnvironment = .shared) -> Migration {
        return Self.migrateLegacyItems(passcodeService: passcodeService, walletServicePrefixes: walletServicePrefixes, legacyItemsBelongToThisApp: legacyItemsBelongToThisApp, environment: environment, keychain: Self.system)
    }

    static func migrateLegacyItems(passcodeService: String, walletServicePrefixes: [String], legacyItemsBelongToThisApp: Bool, environment: PasscodeEnvironment, keychain: Keychain) -> Migration {
        guard environment.keychainScope != nil, legacyItemsBelongToThisApp else {
            return .nothingToMigrate
        }
        guard keychain.isUnlocked() else {
            return .keychainLocked
        }
        let credential: Data
        let device: Data
        switch (keychain.read(passcodeService, "credential"), keychain.read(passcodeService, "device")) {
        case let (.found(credentialData), .found(deviceData)):
            credential = credentialData
            device = deviceData
        case (.locked, _), (_, .locked):
            return .keychainLocked
        case let (.failed(status), _), let (_, .failed(status)):
            return .failed(status)
        default:
            return .nothingToMigrate
        }
        let scopedPasscodeService = Self.service(passcodeService, environment: environment)
        for (account, value) in [("credential", credential), ("device", device)] {
            switch keychain.read(scopedPasscodeService, account) {
            case .absent:
                break
            case let .found(existing):
                guard existing == value else {
                    return .nothingToMigrate
                }
            case .notReadable:
                return .nothingToMigrate
            case .locked:
                return .keychainLocked
            case let .failed(status):
                return .failed(status)
            }
        }
        let listed = keychain.listGenericPasswords()
        guard listed.status == errSecSuccess else {
            return .failed(listed.status)
        }
        let scopePrefix = Self.service("", environment: environment)
        let scopedItems = listed.items.compactMap { item -> (service: String, account: String)? in
            guard item.service.hasPrefix(scopePrefix) else {
                return nil
            }
            return (String(item.service.dropFirst(scopePrefix.count)), item.account)
        }
        var scopedGroups: [String: [(service: String, account: String)]] = [:]
        for group in Self.itemGroups(scopedItems, servicePrefixes: walletServicePrefixes) {
            scopedGroups[group.name] = group.items
        }
        var items: [(service: String, account: String, data: Data)] = []
        groups: for group in Self.itemGroups(listed.items, servicePrefixes: walletServicePrefixes) {
            var groupItems: [(service: String, account: String, data: Data)] = []
            for (service, account) in group.items {
                switch keychain.read(service, account) {
                case let .found(data):
                    groupItems.append((service, account, data))
                case .absent:
                    break
                case .notReadable:
                    continue groups
                case .locked:
                    return .keychainLocked
                case let .failed(status):
                    return .failed(status)
                }
            }
            for (service, account) in scopedGroups[group.name] ?? [] {
                guard let original = groupItems.first(where: { $0.service == service && $0.account == account }) else {
                    continue groups
                }
                switch keychain.read(Self.service(service, environment: environment), account) {
                case let .found(data):
                    guard data == original.data else {
                        continue groups
                    }
                case .absent:
                    break
                case .notReadable:
                    continue groups
                case .locked:
                    return .keychainLocked
                case let .failed(status):
                    return .failed(status)
                }
            }
            items.append(contentsOf: groupItems)
        }
        items.append((passcodeService, "device", device))
        items.append((passcodeService, "credential", credential))
        var copied = 0
        for item in items {
            let status = keychain.add(item.data, Self.service(item.service, environment: environment), item.account)
            if status == errSecSuccess {
                copied += 1
            } else if status != errSecDuplicateItem {
                return .failed(status)
            }
        }
        return .migrated(copied)
    }

    static func itemGroups(_ items: [(service: String, account: String)], servicePrefixes: [String]) -> [(name: String, items: [(service: String, account: String)])] {
        var groups: [String: [(order: Int, service: String, account: String)]] = [:]
        for item in items where !item.service.hasPrefix(Self.root) {
            guard let order = servicePrefixes.firstIndex(where: { item.service.hasPrefix($0) }) else {
                continue
            }
            groups[String(item.service.dropFirst(servicePrefixes[order].count)), default: []].append((order, item.service, item.account))
        }
        return groups.keys.sorted().map { name -> (name: String, items: [(service: String, account: String)]) in
            let sorted = groups[name, default: []].sorted { ($0.order, $0.service, $0.account) < ($1.order, $1.service, $1.account) }
            return (name, sorted.map { (service: $0.service, account: $0.account) })
        }
    }

    static func classify(_ status: OSStatus, result: CFTypeRef?, isUnlocked: () -> Bool) -> Read {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                return .failed(errSecDecode)
            }
            return .found(data)
        case errSecItemNotFound:
            return .absent
        case errSecAuthFailed, errSecInteractionNotAllowed:
            return isUnlocked() ? .notReadable : .locked
        default:
            return .failed(status)
        }
    }

    private static func query(service: String, account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false
        ]
    }

    private static func addIfMissing(_ data: Data, service: String, account: String) -> OSStatus {
        var insert = Self.query(service: service, account: account)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil)
    }

    private static func listGenericPasswords() -> (status: OSStatus, items: [(service: String, account: String)]) {
        let search: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound {
            return (errSecSuccess, [])
        }
        guard status == errSecSuccess, let attributes = result as? [[String: Any]] else {
            return (status == errSecSuccess ? errSecDecode : status, [])
        }
        return (errSecSuccess, attributes.compactMap { item in
            guard let service = item[kSecAttrService as String] as? String, let account = item[kSecAttrAccount as String] as? String else {
                return nil
            }
            return (service, account)
        })
    }

    private static func readWithoutInteraction(service: String, account: String) -> Read {
        var search = Self.query(service: service, account: account)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        Self.interactionLock.lock()
        var interactionAllowed: DarwinBoolean = true
        let readInteraction = SecKeychainGetUserInteractionAllowed(&interactionAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        SecKeychainSetUserInteractionAllowed(readInteraction == errSecSuccess ? interactionAllowed.boolValue : true)
        Self.interactionLock.unlock()
        return Self.classify(status, result: result, isUnlocked: Self.isDefaultKeychainUnlocked)
    }

    static func isDefaultKeychainUnlocked() -> Bool {
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else {
            return false
        }
        var status: SecKeychainStatus = 0
        guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else {
            return false
        }
        return status & SecKeychainStatus(kSecUnlockStateStatus) != 0
    }
}
#endif
