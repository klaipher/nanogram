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
