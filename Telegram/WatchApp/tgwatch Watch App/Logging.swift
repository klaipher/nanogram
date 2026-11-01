import Foundation
import OSLog

extension Logger {
    /// Every logger in the app uses this subsystem (filter with `log stream --predicate`).
    static let watchSubsystem = "org.klaipher.Nanogram.watchkitapp"

    init(watchCategory category: String) {
        self.init(subsystem: Logger.watchSubsystem, category: category)
    }
}

extension AuthState {
    /// The case name only, safe for a public log line: the associated values hold the
    /// QR login token, the phone number and the password hint.
    var logDescription: String {
        switch self {
        case .starting: return "starting"
        case .waitTdlibParameters: return "waitTdlibParameters"
        case .waitPhoneNumber: return "waitPhoneNumber"
        case .waitCode: return "waitCode"
        case .waitOtherDeviceConfirmation: return "waitOtherDeviceConfirmation"
        case .waitPassword: return "waitPassword"
        case .ready: return "ready"
        case .loggingOut: return "loggingOut"
        case .closed: return "closed"
        case .failed: return "failed"
        }
    }
}

/// Verbosity of TDLib's own log. TDLib writes it to stderr (the app never sets a log
/// file) and starts at verbosity 5, which includes requests and message contents.
enum TDLibLogPolicy {
    static let environmentKey = "TGWATCH_TDLIB_VERBOSITY"

    /// Release: fatal errors only, whatever the environment says. Debug: errors, or the
    /// level in `TGWATCH_TDLIB_VERBOSITY`.
    static func verbosity(environment: [String: String], isDebugBuild: Bool) -> Int {
        guard isDebugBuild else { return 0 }
        if let raw = environment[environmentKey], let level = Int(raw), level >= 0 {
            return level
        }
        return 1
    }

    static var current: Int {
#if DEBUG
        let isDebugBuild = true
#else
        let isDebugBuild = false
#endif
        return verbosity(environment: ProcessInfo.processInfo.environment, isDebugBuild: isDebugBuild)
    }
}
