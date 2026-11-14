import Foundation
import Observation
import OSLog
@preconcurrency import TDShim

/// Receives lifecycle events from a `TDClient` that need to be reflected in
/// the wider app (registry updates, account removal). Held weakly by TDClient.
@MainActor
protocol TDClientLifecycleDelegate: AnyObject {
    /// `getMe()` returned. Implementor should harvest display name, phone,
    /// user id into the account record.
    func tdClient(_ client: TDClient, didFetchMe me: User)
    /// TDClient self-destructed (stuck-loggingOut watchdog forced a local
    /// `destroy()`). Implementor should drop the account record + dir,
    /// mirroring user-initiated removal.
    ///
    /// **Re-entrancy contract:** the watchdog can fire AFTER an
    /// `awaitClosed()` timeout, by which time the controller may have
    /// already moved on to a different active account. Implementors MUST
    /// identity-check `client` (e.g. `client.account.id == activeAccountId`)
    /// before acting, or they'll remove the wrong account.
    func tdClient(_ client: TDClient, didDestroyItselfWithReason reason: TDClientDestroyReason)
}

enum TDClientDestroyReason: Equatable {
    case stuckLoggingOut
}

@Observable
@MainActor
final class TDClient {

    let account: Account
    var useTestDc: Bool { account.useTestDc }

    private(set) var authState: AuthState = .starting
    private(set) var me: User? = nil
    private(set) var lastError: String? = nil
    let userNames = UserNamesStore()
    private(set) var chatList: ChatListStore? = nil
    private(set) var activeHistory: ChatHistoryStore? = nil

    func setActiveHistory(_ store: ChatHistoryStore?) {
        activeHistory = store
        store?.setViewingActive(isSceneActive)
        store?.setProjectionPaused(!isSceneActive)
    }

    /// False while the app is not frontmost (wrist down, or in the background). The open chat
    /// then holds its read receipts until the user looks again.
    private(set) var isSceneActive = true

    func setSceneActive(_ active: Bool) {
        guard active != isSceneActive else { return }
        isSceneActive = active
        activeHistory?.setViewingActive(active)
        activeHistory?.setProjectionPaused(!active)
        chatList?.setProjectionPaused(!active)
        if active {
            optimizeStorageIfDue()
        }
    }

    func makeChatHistoryLoader() -> ChatHistoryLoader? {
        guard let client else { return nil }
        return TDLibChatHistoryLoader(client: client)
    }

    private(set) var activeStickerPicker: StickerPickerStore? = nil

    func setActiveStickerPicker(_ store: StickerPickerStore?) {
        activeStickerPicker = store
    }

    func makeStickerPickerLoader() -> StickerPickerLoader? {
        guard let client else { return nil }
        return TDLibStickerPickerLoader(client: client)
    }

    /// Auth-state transitions and user-initiated lifecycle calls log at `.notice`
    /// (default level). `.notice` is reliably persisted by Apple's unified log;
    /// `.info` is memory-only for non-system subsystems and disappears from
    /// `log show` after a brief window. Without persistence it's impossible to
    /// tell post-hoc whether a logging-out transition came from the user or from
    /// a server-initiated kick.
    private let logger = Logger(watchCategory: "tdlib")
    /// Creates the TDLib client; production wraps the process's one `TDLibClientManager`.
    typealias ClientMaker = @MainActor (TDUpdateDelivery) -> TDLibClient
    private let makeClient: ClientMaker
    private weak var delegate: TDClientLifecycleDelegate?
    private let qrLinkPublisher: QrLinkPublisher = .defaultProduction()
    /// Per-process UUID exposed to QrLinkPublisher so the CLI can detect a
    /// watch restart mid-poll.
    private let sessionId = UUID()
    private var client: TDLibClient?

    private var hasSentTdlibParameters = false
    private var hasFetchedMe = false

    /// Resumed when the active TDLib client reaches `authorizationStateClosed`.
    /// Multiple waiters are supported so concurrent callers (e.g.
    /// `awaitClosed()` from `AccountManager.switchTo` overlapping with the
    /// stuck-loggingOut watchdog inside `forceDestroy()`) don't clobber each
    /// other's continuation.
    private var closingContinuations: [CheckedContinuation<Void, Never>] = []

    /// Watchdog armed when authState enters `.loggingOut`. If the state hasn't
    /// changed after `kStuckLoggingOutTimeout` it calls `client.destroy()` to
    /// force a local-only logout. Cancelled on any other auth-state transition.
    private var stuckLoggingOutTask: Task<Void, Never>?

    private let storageSchedule: TDLibStorageOptimizationSchedule
    private var storageOptimizationTask: Task<Void, Never>?

    convenience init(account: Account, manager: TDLibClientManager, delegate: TDClientLifecycleDelegate) {
        self.init(account: account, makeClient: { delivery in
            let handlers = delivery.makeHandlers()
            return manager.createClient(updateHandler: handlers.update, responseHandler: handlers.response)
        }, delegate: delegate)
    }

    init(
        account: Account,
        makeClient: @escaping ClientMaker,
        delegate: TDClientLifecycleDelegate,
        storageSchedule: TDLibStorageOptimizationSchedule = .production()
    ) {
        self.account = account
        self.makeClient = makeClient
        self.delegate = delegate
        self.storageSchedule = storageSchedule
    }

    /// Submits the cloud password. Returns `nil` on success, or a user-facing
    /// error message (see `passwordSubmitErrorMessage`) on failure. Does not
    /// touch the shared `lastError` — the password screen owns its own alert.
    func submitPassword(_ password: String) async -> String? {
        guard let client else { return nil }
        do {
            _ = try await client.checkAuthenticationPassword(password: password)
            return nil
        } catch {
            logger.warning("checkAuthenticationPassword failed: \(error.localizedDescription, privacy: .public)")
            return passwordSubmitErrorMessage(error)
        }
    }

    /// Re-requests QR authentication from the `waitPassword` state, driving
    /// TDLib back to `waitOtherDeviceConfirmation`. Valid because
    /// `requestQrCodeAuthentication` is callable from `authorizationStateWaitPassword`
    /// when no auth query is pending. Returns `nil` on success, or a user-facing
    /// error message on failure. Does not touch `authState` — the QR screen
    /// renders via the normal `updateAuthorizationState` path; on failure the
    /// caller (the password screen) shows the message in its own alert and stays
    /// put, so we deliberately avoid the `.failed` transition that
    /// `requestQrCodeAuthenticationIfNeeded()` performs.
    func returnToQrCode() async -> String? {
        guard let client else { return nil }
        logger.notice("returnToQrCode requested by UI")
        do {
            _ = try await client.requestQrCodeAuthentication(otherUserIds: [])
            return nil
        } catch {
            logger.warning("returnToQrCode failed: \(error.localizedDescription, privacy: .public)")
            return humanMessage(error)
        }
    }

    func logOut() async {
        guard let client else { return }
        lastError = nil
        logger.notice("logOut requested by UI")
        do {
            _ = try await client.logOut()
        } catch {
            logger.warning("logOut failed: \(error.localizedDescription, privacy: .public)")
            lastError = humanMessage(error)
        }
    }

    /// Closes the TDLib client without ending the server-side session. Used
    /// by `AccountManager` when switching to a different account: the
    /// previous account stays signed in, its db dir stays valid. Pair with
    /// `awaitClosed()`.
    func close() async {
        guard let client else { return }
        do {
            _ = try await client.close()
        } catch {
            logger.warning("client.close failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Awaits `authorizationStateClosed` (or 5s timeout). Used by
    /// `AccountManager` to orchestrate switch / removal. Safe to call when
    /// `client` is nil — resolves immediately.
    func awaitClosed(timeout: TimeInterval = 5) async {
        guard client != nil else { return }
        if case .closed = authState { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.closingContinuations.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !self.closingContinuations.isEmpty {
                        self.logger.warning("awaitClosed: timed out after \(Int(timeout))s; forcing recreate")
                        self.resumeClosingIfPending()
                    }
                }
            }
        }
    }

    func start() {
        switch validateSecrets(apiId: Secrets.apiId, apiHash: Secrets.apiHash) {
        case .failure(let err):
            authState = .failed(err.humanMessage)
            return
        case .success:
            break
        }

        qrLinkPublisher.clear()
        let delivery = TDUpdateDelivery(logger: logger) { [weak self] updates in
            guard let self else { return }
            for update in updates { self.handle(update) }
        }
        let client = makeClient(delivery)
        self.client = client

        // Synchronous, so the level applies before setTdlibParameters and any chat request.
        do {
            try Self.setLogVerbosity(TDLibLogPolicy.current, client: client)
        } catch {
            logger.warning("setLogVerbosityLevel failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sets TDLib's log verbosity with a synchronous `td_execute` (process-wide, not per client).
    nonisolated static func setLogVerbosity(_ level: Int, client: TDLibClient) throws {
        let query = DTO(SetLogVerbosityLevel(newVerbosityLevel: level), encoder: client.encoder)
        let result = try client.execute(query: query)
        if let type = result?["@type"] as? String, type != "ok" {
            throw TDError(code: 500, message: "setLogVerbosityLevel returned \(type)")
        }
    }

    private func handle(_ update: Update) {
        if case .updateAuthorizationState(let upd) = update {
            lastError = nil
            let mapped = mapAuthState(upd.authorizationState)
            authState = mapped
            logger.notice("authState -> \(mapped.logDescription, privacy: .public)")

            switch mapped {
            case .waitOtherDeviceConfirmation(let link):
                qrLinkPublisher.publish(link: link, useTestDc: useTestDc, sessionId: sessionId)
            default:
                qrLinkPublisher.clear()
            }

            if case .waitTdlibParameters = mapped, !hasSentTdlibParameters {
                hasSentTdlibParameters = true
                sendTdlibParameters()
            }
            if case .waitPhoneNumber = mapped {
                requestQrCodeAuthenticationIfNeeded()
            }
            if case .ready = mapped {
                if !hasFetchedMe {
                    hasFetchedMe = true
                    fetchMe()
                    sendReadyOptions()
                    optimizeStorageIfDue()
                }
                if chatList == nil, let client {
                    chatList = ChatListStore(
                        loader: TDLibChatListLoader(client: client),
                        selfUserId: me?.id,
                        userNames: userNames,
                        coalesceUpdates: true
                    )
                    chatList?.setProjectionPaused(!isSceneActive)
                    configureWidgetSnapshot()
                }
                registerForPushIfEnabled()
            }
            switch mapped {
            case .ready:
                break
            default:
                storageOptimizationTask?.cancel()
                storageOptimizationTask = nil
            }
            if case .loggingOut = mapped {
                chatList = nil
                activeHistory = nil
                activeStickerPicker = nil
                armStuckLoggingOutWatchdog()
            } else {
                stuckLoggingOutTask?.cancel()
                stuckLoggingOutTask = nil
            }
            if case .closed = mapped {
                chatList = nil
                activeHistory = nil
                activeStickerPicker = nil
                resumeClosingIfPending()
            }
            return
        }

        userNames.handle(update)
        chatList?.handle(update)
        activeHistory?.handle(update)
        activeStickerPicker?.handle(update)
    }

    /// Fired on every `waitPhoneNumber` transition. TDLib advances to
    /// `waitOtherDeviceConfirmation` immediately on success so we don't see
    /// `waitPhoneNumber` twice in one session; on the off chance we do (e.g.
    /// logout loop), TDLib treats the second call as idempotent or errors —
    /// both handled.
    private func requestQrCodeAuthenticationIfNeeded() {
        guard let client else { return }
        Task { [weak self, logger, client] in
            do {
                _ = try await client.requestQrCodeAuthentication(otherUserIds: [])
            } catch {
                logger.warning("requestQrCodeAuthentication failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    self?.lastError = humanMessage(error)
                    self?.authState = .failed(humanMessage(error))
                }
            }
        }
    }

    /// Number of seconds we wait for `.loggingOut` to clear on its own before
    /// concluding that TDLib is stuck and forcing a local destroy. A normal
    /// client-initiated logout completes in well under 2s; we picked 15s to
    /// stay comfortably above that while still recovering quickly.
    private static let kStuckLoggingOutTimeout: TimeInterval = 15

    /// Recovery for the "TDLib is stuck on .loggingOut forever" failure mode
    /// we hit when Telegram's backend force-terminates the session unilaterally
    /// (e.g. anti-third-party-client heuristic kicks in). The local db is left
    /// marked "logging out, please confirm with server" but the corresponding
    /// auth_key is already gone server-side, so every reconnect to the home DC
    /// fails with `auth_key_id mismatch` and the logout never completes —
    /// TDLib has no built-in timeout for this loop.
    ///
    /// `client.destroy()` drops the local db without server confirmation, which
    /// breaks the loop. With multi-account, the destroy is followed by a
    /// delegate callback so `AccountManager` can drop this account's record +
    /// dir entirely (matching the "logout = remove" UX). See
    /// CLAUDE.md "TDLib gets stuck on authorizationStateLoggingOut" gotcha.
    private func armStuckLoggingOutWatchdog() {
        stuckLoggingOutTask?.cancel()
        let timeout = Self.kStuckLoggingOutTimeout
        stuckLoggingOutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.forceDestroyIfStillStuck(timeout: timeout)
        }
    }

    private func forceDestroyIfStillStuck(timeout: TimeInterval) async {
        guard case .loggingOut = authState else { return }
        logger.notice("authState stuck on loggingOut for \(Int(timeout))s — calling destroy()")
        await forceDestroy()
    }

    /// Calls `destroy()` on the active TDLib client, awaits the resulting
    /// `authorizationStateClosed`, then signals the delegate so
    /// `AccountManager` can drop this account's record + dir.
    private func forceDestroy() async {
        guard let captured = client else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.closingContinuations.append(continuation)
            Task { [logger, captured] in
                do {
                    _ = try await captured.destroy()
                } catch {
                    logger.warning("destroy() failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if !self.closingContinuations.isEmpty {
                        self.logger.warning("forceDestroy: timed out waiting for closed; forcing recreate")
                        self.resumeClosingIfPending()
                    }
                }
            }
        }

        me = nil
        chatList = nil
        activeHistory = nil
        activeStickerPicker = nil
        hasSentTdlibParameters = false
        hasFetchedMe = false
        lastError = nil
        qrLinkPublisher.clear()
        stuckLoggingOutTask = nil
        client = nil
        // authState was already moved to .closed by handle(update) when
        // TDLib emitted authorizationStateClosed after destroy().
        delegate?.tdClient(self, didDestroyItselfWithReason: .stuckLoggingOut)
    }

    private func sendTdlibParameters() {
        guard let client else { return }
        let useTest = self.useTestDc
        let accountId = account.id
        // Server-visible: the real language, build and OS version only with the owner's flag.
        let systemInfo = TdlibSystemInfo.resolve(enabled: WatchFeatureFlags.isEnabled(.localizedTdlibParameters))
        Task { [weak self, logger, client] in
            let layout = await Task.detached(priority: .userInitiated) {
                TDLibStorage.prepareLayout(accountId: accountId, roots: .production)
            }.value
            logger.notice("tdlib files in \(layout.filesArePurgeable ? "caches" : "database directory", privacy: .public)")
            do {
                _ = try await client.setTdlibParameters(
                    apiHash: Secrets.apiHash,
                    apiId: Secrets.apiId,
                    applicationVersion: systemInfo.applicationVersion,
                    databaseDirectory: layout.databaseDirectory.path,
                    databaseEncryptionKey: nil,
                    deviceModel: "Apple Watch",
                    filesDirectory: layout.filesDirectory.path,
                    systemLanguageCode: systemInfo.languageCode,
                    systemVersion: systemInfo.systemVersion,
                    useChatInfoDatabase: true,
                    useFileDatabase: true,
                    useMessageDatabase: true,
                    useSecretChats: false,
                    useTestDc: useTest
                )
            } catch {
                logger.error("setTdlibParameters failed: \(error.localizedDescription, privacy: .public)")
                Task { @MainActor in
                    self?.authState = .failed(humanMessage(error))
                }
            }
        }
    }

    // MARK: - Widget summary (IOS-WATCH-WIDGET-1)

    private var widgetPublisher: WidgetSnapshotPublisher?

    /// Feeds the App Group summary from the chat list. Flag `widgetSnapshot`; a no-op without the App Group.
    private func configureWidgetSnapshot() {
        guard WatchFeatureFlags.isEnabled(.widgetSnapshot) else { return }
        let publisher = WidgetSnapshotPublisher(store: .appGroup())
        guard publisher.isAvailable else {
            logger.notice("widget snapshot enabled but the App Group is missing from the entitlements")
            return
        }
        widgetPublisher = publisher
        chatList?.onProjected = { [weak self, weak publisher] in
            publisher?.requestPublish { [weak self] in self?.chatList?.unreadInputs() ?? [] }
        }
    }

    /// Background refresh: writes the summary now, from the cache, even though the projection is paused.
    func publishWidgetSnapshotNow() {
        guard let chatList else { return }
        widgetPublisher?.publishNow(inputs: chatList.unreadInputs())
    }

    // MARK: - Push registration (WATCH-INT-1)

    private var pushObserver: PushTokenObservation?
    private var registeredPushToken: Data?

    /// Registers the watch's APNs token with TDLib once the account is ready. Flag `pushRegistration`; needs the
    /// push entitlement (owner steps in NANOGRAM-CHANGES.md). Server-visible: the account gets a new device.
    private func registerForPushIfEnabled() {
        guard WatchFeatureFlags.isEnabled(.pushRegistration), pushObserver == nil else { return }
        pushObserver = PushTokenStore.shared.observe { [weak self] token in
            self?.sendRegisterDevice(token)
        }
    }

    private func sendRegisterDevice(_ token: Data) {
        guard let client, registeredPushToken != token else { return }
        registeredPushToken = token
        let query = RegisterDeviceQuery(tokenHex: PushRegistration.hexString(token), isSandbox: PushRegistration.isSandbox)
        do {
            try client.send(query: query, completion: Self.registerDeviceCompletion(logger: logger))
        } catch {
            registeredPushToken = nil
            logger.warning("registerDevice not sent: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Built outside the main actor: TDLib calls it on its own queue, and a closure written inside this
    /// `@MainActor` class would be main-actor isolated, which Swift 6 checks on entry.
    nonisolated private static func registerDeviceCompletion(logger: Logger) -> (Data) -> Void {
        return { data in
            if let text = String(data: data, encoding: .utf8), text.contains("\"@type\":\"error\"") {
                logger.warning("registerDevice failed")
            }
        }
    }

    private func sendReadyOptions() {
        guard let client else { return }
        Task { [logger, client] in
            for option in TDLibReadyOptions.all {
                do {
                    _ = try await client.setOption(name: option.name, value: option.value)
                } catch {
                    logger.warning("setOption \(option.name ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Trims downloads once the account is ready and whenever the app comes forward, at most
    /// once per `TDLibStorageOptimization.minimumInterval` per account.
    private func optimizeStorageIfDue() {
        guard case .ready = authState, isSceneActive, client != nil, storageOptimizationTask == nil else { return }
        let accountId = account.id
        guard storageSchedule.isDue(accountId: accountId) else { return }
        storageOptimizationTask = Task { [weak self] in
            try? await Task.sleep(for: TDLibStorageOptimization.startDelay)
            guard !Task.isCancelled else { return }
            await self?.runStorageOptimization(accountId: accountId)
        }
    }

    private func runStorageOptimization(accountId: UUID) async {
        // A cancelled run was already replaced by `handle`; leave its successor in place.
        defer { if !Task.isCancelled { storageOptimizationTask = nil } }
        guard case .ready = authState, let client else { return }
        // Marked before the run so a foreground during it does not start a second one.
        storageSchedule.markRun(accountId: accountId)
        do {
            let deleted = try await TDLibStorageOptimization.run(client: client)
            logger.notice("storage optimized: deleted \(deleted.count, privacy: .public) files, \(deleted.size, privacy: .public) bytes")
        } catch {
            logger.warning("optimizeStorage failed: \(error.localizedDescription, privacy: .public)")
            storageSchedule.clearRun(accountId: accountId)
        }
    }

    private func fetchMe() {
        guard let client else { return }
        Task { [weak self, logger, client] in
            do {
                let user = try await client.getMe()
                Task { @MainActor in
                    guard let self else { return }
                    self.me = user
                    self.chatList?.setSelfUserId(user.id)
                    self.delegate?.tdClient(self, didFetchMe: user)
                }
            } catch {
                logger.warning("getMe failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func resumeClosingIfPending() {
        let waiters = closingContinuations
        closingContinuations.removeAll()
        for c in waiters {
            c.resume()
        }
    }
}

/// Options set each time an account becomes ready.
enum TDLibReadyOptions {
    /// - use_storage_optimizer: TDLib keeps every downloaded file forever unless its storage
    ///   optimizer runs, which on a watch slowly fills the disk. With it on, about once a day
    ///   TDLib deletes files not opened for 23 hours and trims the cache to 100 MB (TDLib's
    ///   defaults; files created in the last hour are kept). `TDLibStorageOptimization` covers
    ///   the types it skips.
    /// - disable_persistent_network_statistics: the watch shows no network statistics, and
    ///   TDLib writes them to its binlog after every ~1 KB of traffic per network type.
    ///
    /// The other disk-saving options are left off; `TDLibDiskOptionsTests` lists why.
    static let all: [SetOption] = [
        SetOption(name: "use_storage_optimizer", value: .optionValueBoolean(OptionValueBoolean(value: true))),
        SetOption(name: "disable_persistent_network_statistics", value: .optionValueBoolean(OptionValueBoolean(value: true))),
    ]
}
