import Foundation

/// Where a `td_receive` payload goes: which client, whether it answers a request (`@extra`), and
/// whether it closes the client.
public enum TDLibResponseRoute {
    public struct Route: Equatable, Sendable {
        public let clientId: Int32
        public let extra: String?
        public let closesClient: Bool

        public init(clientId: Int32, extra: String?, closesClient: Bool) {
            self.clientId = clientId
            self.extra = extra
            self.closesClient = closesClient
        }
    }

    /// The scan where it applies, otherwise a full parse. nil when the payload is not a JSON object.
    public static func route(_ data: Data) -> Route? {
        scan(data) ?? parse(data)
    }

    /// Reads the route from the bytes without parsing the payload.
    ///
    /// td_json writes `"@type"` first and appends `,"@extra":<extra>` (when the request had one)
    /// and `,"@client_id":<id>` as the last keys of every object it returns
    /// (td/telegram/ClientJson.cpp, `from_response`). Inside a JSON string every quote is escaped,
    /// so `,"@extra":"` can only be that key; nested objects never carry it. Returns nil for
    /// anything not of that shape (or an `@extra` string with escapes, which this client never
    /// sends), and the caller parses the payload instead.
    public static func scan(_ data: Data) -> Route? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Route? in
            let b = raw.bindMemory(to: UInt8.self)
            let n = b.count
            guard n >= 2, b[n - 1] == UInt8(ascii: "}"), startsWith(b, typePrefix, at: 0) else { return nil }

            // ,"@client_id":<digits>}
            var digitsStart = n - 1
            while digitsStart > 0, isDigit(b[digitsStart - 1]) { digitsStart -= 1 }
            guard digitsStart < n - 1, n - 1 - digitsStart <= 10 else { return nil }
            let clientKeyStart = digitsStart - clientIdKey.count
            guard clientKeyStart > 0, startsWith(b, clientIdKey, at: clientKeyStart) else { return nil }
            var clientId: Int64 = 0
            for i in digitsStart..<(n - 1) { clientId = clientId * 10 + Int64(b[i] - UInt8(ascii: "0")) }
            guard clientId <= Int64(Int32.max) else { return nil }

            // ,"@extra":"<value>" right before it, when the previous value is a string.
            var extra: String? = nil
            let valueEnd = clientKeyStart - 1   // the closing quote, if any
            if valueEnd > 0, b[valueEnd] == UInt8(ascii: "\"") {
                var m = valueEnd - extraKey.count
                while m >= 0 {
                    if b[m] == UInt8(ascii: ","), startsWith(b, extraKey, at: m) { break }
                    m -= 1
                }
                if m >= 0 {
                    let valueStart = m + extraKey.count
                    for i in valueStart..<valueEnd where b[i] == UInt8(ascii: "\"") || b[i] == UInt8(ascii: "\\") {
                        return nil
                    }
                    extra = String(decoding: UnsafeBufferPointer(rebasing: b[valueStart..<valueEnd]), as: UTF8.self)
                }
            }

            var closes = false
            if startsWith(b, authUpdatePrefix, at: 0) {
                closes = contains(b, closedState, from: authUpdatePrefix.count, to: clientKeyStart)
            }
            return Route(clientId: Int32(clientId), extra: extra, closesClient: closes)
        }
    }

    /// The full parse the manager always used to do.
    static func parse(_ data: Data) -> Route? {
        guard let dictionary = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
            return nil
        }
        var closes = false
        if let state = dictionary["authorization_state"] as? [String: Any],
           (state["@type"] as? String) == "authorizationStateClosed" {
            closes = true
        }
        return Route(
            clientId: dictionary["@client_id"] as? Int32 ?? 1,
            extra: dictionary["@extra"] as? String,
            closesClient: closes
        )
    }

    private static let typePrefix = Array(#"{"@type":""#.utf8)
    private static let clientIdKey = Array(#","@client_id":"#.utf8)
    private static let extraKey = Array(#","@extra":""#.utf8)
    private static let authUpdatePrefix = Array(#"{"@type":"updateAuthorizationState","#.utf8)
    private static let closedState = Array(#""authorization_state":{"@type":"authorizationStateClosed""#.utf8)

    @inline(__always)
    private static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

    private static func startsWith(_ b: UnsafeBufferPointer<UInt8>, _ prefix: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + prefix.count <= b.count else { return false }
        for i in 0..<prefix.count where b[offset + i] != prefix[i] { return false }
        return true
    }

    private static func contains(_ b: UnsafeBufferPointer<UInt8>, _ needle: [UInt8], from: Int, to: Int) -> Bool {
        guard let first = needle.first, to - from >= needle.count else { return false }
        var i = from
        while i + needle.count <= to {
            if b[i] == first, startsWith(b, needle, at: i) { return true }
            i += 1
        }
        return false
    }
}
