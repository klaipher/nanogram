import Foundation

public struct NotificationsPresentationData: Codable, Equatable {
    public var applicationLockedMessageString: String
    public var applicationLockedStoryString: String?
    public var incomingCallString: String
    /// "Incoming Call" in the app's language, shown when the caller's name is hidden.
    public var incomingCallTitleString: String?
    
    public init(applicationLockedMessageString: String, applicationLockedStoryString: String?, incomingCallString: String, incomingCallTitleString: String? = nil) {
        self.incomingCallTitleString = incomingCallTitleString
        self.applicationLockedMessageString = applicationLockedMessageString
        self.applicationLockedStoryString = applicationLockedStoryString
        self.incomingCallString = incomingCallString
    }
}

public func notificationsPresentationDataPath(rootPath: String) -> String {
    return rootPath + "/notificationsPresentationData.json"
}
