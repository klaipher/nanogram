public import Foundation

// Grammar: docs/specs/search-operators.md (shared with the Mac and Android apps).

public enum SearchOperatorType: String, CaseIterable, Sendable {
    case photo, video, file, link, voice, music, gif, round, poll, pinned, contact, geo, mention
}

public struct ParsedSearchQuery: Equatable, Sendable {
    public var text: String
    // The `from:` value as typed. It stays here until the caller resolves it to a peer.
    public var fromName: String?
    public var fromRawToken: String?
    public var minDate: Int32?
    public var maxDate: Int32?
    public var type: SearchOperatorType?

    public init(text: String, fromName: String? = nil, fromRawToken: String? = nil, minDate: Int32? = nil, maxDate: Int32? = nil, type: SearchOperatorType? = nil) {
        self.text = text
        self.fromName = fromName
        self.fromRawToken = fromRawToken
        self.minDate = minDate
        self.maxDate = maxDate
        self.type = type
    }

    public var hasOperators: Bool {
        return self.fromName != nil || self.minDate != nil || self.maxDate != nil || self.type != nil
    }

    // The text with the `from:` token put back, for a name that did not resolve.
    public func textRestoringFrom() -> String {
        guard let raw = self.fromRawToken else {
            return self.text
        }
        return self.text.isEmpty ? raw : self.text + " " + raw
    }
}

public enum SearchOperators {
    public static func parse(_ query: String, now: Date = Date(), calendar: Calendar = .current, supportedTypes: Set<SearchOperatorType> = Set(SearchOperatorType.allCases)) -> ParsedSearchQuery {
        var plain: [String] = []
        var fromName: String?
        var fromRaw: String?
        var beforeMax: Int32?
        var afterMin: Int32?
        var dateOnly: (Int32, Int32)?
        var type: SearchOperatorType?

        for token in tokenize(query) {
            guard let colon = token.firstIndex(of: ":") else {
                plain.append(token)
                continue
            }
            let name = token[token.startIndex ..< colon].lowercased()
            var value = String(token[token.index(after: colon)...])
            if value.hasPrefix("\"") {
                if value.count >= 2 && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                } else {
                    plain.append(token)
                    continue
                }
            }
            if value.isEmpty {
                plain.append(token)
                continue
            }
            switch name {
            case "from":
                var handle = value
                if handle.hasPrefix("@") {
                    handle.removeFirst()
                }
                if handle.isEmpty {
                    plain.append(token)
                } else {
                    fromName = handle
                    fromRaw = token
                }
            case "before", "after", "date":
                guard let range = dateRange(value, now: now, calendar: calendar) else {
                    plain.append(token)
                    continue
                }
                switch name {
                case "before":
                    beforeMax = range.0
                case "after":
                    afterMin = range.1
                default:
                    dateOnly = range
                }
            case "type":
                if let parsed = SearchOperatorType(rawValue: value.lowercased()), supportedTypes.contains(parsed) {
                    type = parsed
                } else {
                    plain.append(token)
                }
            default:
                plain.append(token)
            }
        }

        var minDate = afterMin
        var maxDate = beforeMax
        if let dateOnly {
            minDate = max(minDate ?? dateOnly.0, dateOnly.0)
            maxDate = min(maxDate ?? dateOnly.1, dateOnly.1)
        }
        return ParsedSearchQuery(text: plain.joined(separator: " "), fromName: fromName, fromRawToken: fromRaw, minDate: minDate, maxDate: maxDate, type: type)
    }

    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuote = false
        for character in query {
            if character == "\"" {
                // A quote opens only right after "name:", so a quote inside plain words stays as typed.
                if !inQuote && current.hasSuffix(":") {
                    inQuote = true
                } else if inQuote {
                    inQuote = false
                }
                current.append(character)
            } else if character.isWhitespace && !inQuote {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            if inQuote, let space = current.firstIndex(where: { $0.isWhitespace }) {
                // Unclosed quote: the first word is the token, the rest are ordinary words.
                tokens.append(String(current[current.startIndex ..< space]))
                tokens.append(contentsOf: current[space...].split(whereSeparator: { $0.isWhitespace }).map(String.init))
            } else {
                tokens.append(current)
            }
        }
        return tokens
    }

    // Start of the range and its end (exclusive), as Unix seconds.
    private static func dateRange(_ value: String, now: Date, calendar: Calendar) -> (Int32, Int32)? {
        let lower = value.lowercased()
        let start: Date
        let end: Date
        if lower == "today" || lower == "yesterday" {
            let today = calendar.startOfDay(for: now)
            guard let day = lower == "today" ? today : calendar.date(byAdding: .day, value: -1, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            start = day
            end = next
        } else {
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard (1 ... 3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else {
                return nil
            }
            guard parts[0].count == 4, let year = Int(parts[0]), (1970 ... 2100).contains(year) else {
                return nil
            }
            var components = DateComponents()
            components.year = year
            components.month = 1
            components.day = 1
            let unit: Calendar.Component
            if parts.count >= 2 {
                guard parts[1].count == 2, let month = Int(parts[1]), (1 ... 12).contains(month) else {
                    return nil
                }
                components.month = month
                unit = .month
            } else {
                unit = .year
            }
            var finalUnit = unit
            if parts.count == 3 {
                guard parts[2].count == 2, let day = Int(parts[2]), (1 ... 31).contains(day) else {
                    return nil
                }
                components.day = day
                finalUnit = .day
            }
            guard let first = calendar.date(from: components) else {
                return nil
            }
            let check = calendar.dateComponents([.year, .month, .day], from: first)
            guard check.year == components.year, check.month == components.month, check.day == components.day,
                  let next = calendar.date(byAdding: finalUnit, value: 1, to: first) else {
                return nil
            }
            start = first
            end = next
        }
        guard let startSeconds = Int32(exactly: Int64(start.timeIntervalSince1970)),
              let endSeconds = Int32(exactly: Int64(end.timeIntervalSince1970)) else {
            return nil
        }
        return (startSeconds, endSeconds)
    }
}
