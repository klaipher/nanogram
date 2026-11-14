import Foundation

public enum StarRefStartParamPrefixes {
    public static let defaultPrefixes = ["_tgr_"]

    /// The server sends an array of strings; a single string is accepted too.
    public static func prefixes(appConfiguration: JSON?) -> [String] {
        guard let appConfiguration, case let .dictionary(values) = appConfiguration, let value = values["starref_start_param_prefixes"] else {
            return defaultPrefixes
        }
        var result: [String] = []
        switch value {
        case let .string(string):
            result = [string]
        case let .array(items):
            for item in items {
                if case let .string(string) = item {
                    result.append(string)
                }
            }
        default:
            break
        }
        result = result.filter { !$0.isEmpty }
        return result.isEmpty ? defaultPrefixes : result
    }

    public static func referrer(startParam: String, prefixes: [String]) -> String? {
        for prefix in prefixes where startParam.hasPrefix(prefix) {
            return String(startParam.dropFirst(prefix.count))
        }
        return nil
    }
}
