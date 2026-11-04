import Foundation

public enum VenueSearchBackend: Equatable, Sendable {
    case none
    case mapKit
    case bot(latitude: Double, longitude: Double)

    public var usesBot: Bool {
        if case .bot = self {
            return true
        }
        return false
    }
}

public enum VenueSearchPolicy {
    public static func roundedForBot(_ coordinate: Double) -> Double {
        return (coordinate * 100.0).rounded() / 100.0
    }

    public static func backend(isSecretChat: Bool, isStory: Bool, userRequested: Bool, latitude: Double, longitude: Double) -> VenueSearchBackend {
        if isSecretChat {
            return isStory ? .none : .mapKit
        }
        if !isStory {
            return .mapKit
        }
        if !userRequested {
            return .none
        }
        return .bot(latitude: roundedForBot(latitude), longitude: roundedForBot(longitude))
    }
}
