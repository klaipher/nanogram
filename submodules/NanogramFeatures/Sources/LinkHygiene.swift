import Foundation

// Rules: docs/specs/search-operators.md (link hygiene) and shared/data/link-tracking-params.txt (nanogram-deps).

public struct TrackingParameterList: Sendable {
    private struct Rule: Sendable {
        let name: String
        let isPrefix: Bool
        let host: String?
    }

    private let rules: [Rule]

    public init(fileContents: String) {
        var rules: [Rule] = []
        for rawLine in fileContents.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            var namePart = line
            var host: String?
            if let bar = line.firstIndex(of: "|") {
                namePart = String(line[line.startIndex ..< bar])
                host = String(line[line.index(after: bar)...]).lowercased()
            }
            let isPrefix = namePart.hasSuffix("*")
            if isPrefix {
                namePart.removeLast()
            }
            if namePart.isEmpty {
                continue
            }
            rules.append(Rule(name: namePart.lowercased(), isPrefix: isPrefix, host: host))
        }
        self.rules = rules
    }

    public var ruleCount: Int {
        return self.rules.count
    }

    public func isTracking(name: String, host: String) -> Bool {
        let name = name.lowercased()
        let host = host.lowercased()
        for rule in self.rules {
            if let ruleHost = rule.host, host != ruleHost && !host.hasSuffix("." + ruleHost) {
                continue
            }
            if rule.isPrefix ? name.hasPrefix(rule.name) : name == rule.name {
                return true
            }
        }
        return false
    }

    // The built-in list. It mirrors shared/data/link-tracking-params.txt (nanogram-deps) (a test compares the two).
    public static let standard = TrackingParameterList(fileContents: """
    utm_*
    fbclid
    gclid
    gclsrc
    dclid
    gbraid
    wbraid
    msclkid
    twclid
    ttclid
    li_fat_id
    igshid
    igsh
    mc_eid
    mc_cid
    _hsenc
    _hsmi
    __hssc
    __hstc
    __hsfp
    hsctatracking
    mkt_tok
    oly_anon_id
    oly_enc_id
    vero_id
    vero_conv
    yclid
    ysclid
    _openstat
    ref_src
    ref_url
    s_cid
    spm
    scm
    si|youtube.com
    si|youtu.be
    si|open.spotify.com
    si|music.youtube.com
    feature|youtube.com
    pp|youtube.com
    ref|amazon.com
    tag|amazon.com
    pd_rd_*|amazon.com
    pf_rd_*|amazon.com
    share_id|tiktok.com
    is_copy_url|tiktok.com
    is_from_webapp|tiktok.com
    sender_device|tiktok.com
    refsrc|facebook.com
    __tn__|facebook.com
    __cft__*|facebook.com
    """)
}

public enum LinkHygiene {
    // Removes tracking parameters from an http(s) link. Anything else, and links with nothing to remove, come back as given.
    public static func strippingTracking(_ link: String, list: TrackingParameterList = .standard) -> String {
        guard let question = link.firstIndex(of: "?"),
              !link[link.startIndex ..< question].contains("#"),
              let scheme = link.range(of: "://"), scheme.upperBound <= question,
              ["http", "https"].contains(link[link.startIndex ..< scheme.lowerBound].lowercased()) else {
            return link
        }
        let afterScheme = link[scheme.upperBound ..< question]
        let authority = afterScheme.prefix(while: { $0 != "/" })
        var host = String(authority)
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        if let colon = host.lastIndex(of: ":"), !host.hasSuffix("]") {
            host = String(host[host.startIndex ..< colon])
        }

        let base = link[link.startIndex ..< question]
        let rest = link[link.index(after: question)...]
        var fragment = ""
        var query = rest
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[hash...])
            query = rest[rest.startIndex ..< hash]
        }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var removed = false
        for pair in pairs {
            let name = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let decoded = name.removingPercentEncoding ?? name
            if !decoded.isEmpty && list.isTracking(name: decoded, host: host) {
                removed = true
            } else {
                kept.append(pair)
            }
        }
        if !removed {
            return link
        }
        let keptQuery = kept.joined(separator: "&")
        return String(base) + (keptQuery.isEmpty ? "" : "?" + keptQuery) + fragment
    }

    // t.me, telegram.me and tg:// links: the ones "Confirm Telegram links" asks about.
    public static func isTelegramLink(_ link: String) -> Bool {
        let lower = link.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasPrefix("tg://") {
            return true
        }
        for scheme in ["https://", "http://"] where lower.hasPrefix(scheme) {
            let host = lower.dropFirst(scheme.count).prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
            return ["t.me", "telegram.me", "telegram.dog", "www.t.me", "www.telegram.me"].contains(String(host))
        }
        return false
    }
}
