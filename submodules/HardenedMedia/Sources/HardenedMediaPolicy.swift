public struct HardenedMediaPolicy: Equatable, Sendable {
    public let isActive: Bool

    public static let inactive = HardenedMediaPolicy(isActive: false)
    public static let lockdown = HardenedMediaPolicy(isActive: true)

    public static var current: HardenedMediaPolicy {
        return HardenedMediaPolicy(lockdownModeEnabled: LockdownMode.current)
    }

    private init(isActive: Bool) {
        self.isActive = isActive
    }

    public init(lockdownModeEnabled: Bool) {
        self.isActive = lockdownModeEnabled
    }

    public func allowsAutomaticDownload(fromContact: Bool) -> Bool {
        return !self.isActive || fromContact
    }

    /// Whether the Notification Service may download media from the sender and attach it to the notification. It runs
    /// with no user action, so it follows the auto-download rule. The extension cannot tell who is a contact without
    /// opening more of the account than a push needs, so it passes `false`: under Lockdown Mode a notification shows
    /// text only.
    public func allowsNotificationMedia(fromContact: Bool) -> Bool {
        return self.allowsAutomaticDownload(fromContact: fromContact)
    }

    public func allowsAutoplay(fromContact: Bool) -> Bool {
        return !self.isActive || fromContact
    }

    public var generatesLinkPreviewsForReceivedLinks: Bool {
        return !self.isActive
    }

    public var confirmsOutgoingLinkPreviews: Bool {
        return self.isActive
    }

    public var allowsCodeHighlighting: Bool {
        return !self.isActive
    }

    public var allowsMiniAppAutoOpen: Bool {
        return !self.isActive
    }
}
