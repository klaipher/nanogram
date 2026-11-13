import Foundation
import Postbox

/// Language codes whose suggestion the person has already seen. Kept under its own preferences key (not inside the
/// upstream `SuggestedLocalizationEntry`) so a suggestion that flips A, B, A is not shown a second time.
final class SuggestedLocalizationSeenCodes: Codable {
    static var key: ValueBoxKey {
        let key = ValueBoxKey(length: 4)
        key.setInt32(0, value: 7001)
        return key
    }
    
    static let maxCount = 16
    
    let codes: [String]
    
    init(codes: [String]) {
        self.codes = codes
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)
        self.codes = try container.decode([String].self, forKey: "c")
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)
        try container.encode(self.codes, forKey: "c")
    }
    
    func inserting(_ code: String) -> SuggestedLocalizationSeenCodes {
        var codes = self.codes.filter { $0 != code }
        codes.append(code)
        if codes.count > SuggestedLocalizationSeenCodes.maxCount {
            codes.removeFirst(codes.count - SuggestedLocalizationSeenCodes.maxCount)
        }
        return SuggestedLocalizationSeenCodes(codes: codes)
    }
}

/// The suggestion entry after the server's configuration named `serverCode`. A missing code keeps what is stored
/// (the configuration may simply not carry one this time; deleting the entry made the next response look like a new
/// suggestion); the same code keeps the entry and its seen flag; a different code starts a new entry that is already
/// seen if that code was seen before.
func reconcileSuggestedLocalization(current: SuggestedLocalizationEntry?, serverCode: String?, seenCodes: [String]) -> SuggestedLocalizationEntry? {
    guard let serverCode else {
        return current
    }
    if let current, current.languageCode == serverCode {
        return current
    }
    return SuggestedLocalizationEntry(languageCode: serverCode, isSeen: seenCodes.contains(serverCode))
}

func suggestedLocalizationTransitionDescription(current: SuggestedLocalizationEntry?, serverCode: String?, result: SuggestedLocalizationEntry?) -> String {
    func describe(_ entry: SuggestedLocalizationEntry?) -> String {
        guard let entry else {
            return "none"
        }
        return "\(entry.languageCode) seen=\(entry.isSeen)"
    }
    return "stored \(describe(current)), server \(serverCode ?? "none") -> \(describe(result))"
}
