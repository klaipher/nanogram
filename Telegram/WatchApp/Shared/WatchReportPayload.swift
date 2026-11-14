public import Foundation

// What the watch hands the iPhone's "Send Report": a few text files in one JSON blob, small enough for
// WatchConnectivity (sendMessage reply or a background file transfer). Compiled into the watch app and the phone's
// WatchReport module.

public struct WatchReportFile: Codable, Equatable, Sendable {
    public var name: String
    public var text: String

    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }
}

public enum WatchReportMessage {
    /// The phone's sendMessage: asks the watch for a fresh report.
    public static let requestKey = "nanogram.watchReport.request"
    /// The watch's reply and the metadata of its file transfers: the encoded payload / a marker.
    public static let payloadKey = "nanogram.watchReport.payload"
    public static let fileMarkerKey = "nanogram.watchReport.file"
    /// Over this the message path is skipped and the file copy is used.
    public static let maximumBytes = 400 * 1024
}

public struct WatchReportPayload: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var created: Date
    public var files: [WatchReportFile]

    public init(version: Int = WatchReportPayload.currentVersion, created: Date, files: [WatchReportFile]) {
        self.version = version
        self.created = created
        self.files = files
    }

    /// Never fails on a long log: the oldest lines of the largest file go first until it fits.
    public func encoded(maximumBytes: Int = WatchReportMessage.maximumBytes) -> Data? {
        var payload = self
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for _ in 0 ..< 64 {
            guard let data = try? encoder.encode(payload) else {
                return nil
            }
            if data.count <= maximumBytes {
                return data
            }
            guard let index = payload.files.indices.max(by: { payload.files[$0].text.utf8.count < payload.files[$1].text.utf8.count }) else {
                return nil
            }
            let text = payload.files[index].text
            let excess = data.count - maximumBytes
            let drop = max(excess + 256, text.utf8.count / 4)
            if drop >= text.utf8.count {
                payload.files[index].text = "[cut: did not fit]\n"
                continue
            }
            let tail = text.utf8.dropFirst(drop)
            var kept = String(decoding: tail, as: UTF8.self)
            if let lineFeed = kept.firstIndex(of: "\n") {
                kept = String(kept[kept.index(after: lineFeed)...])
            }
            payload.files[index].text = "[earlier lines cut to fit the transfer]\n" + kept
        }
        return nil
    }

    public static func decode(_ data: Data) -> WatchReportPayload? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(WatchReportPayload.self, from: data), payload.version == currentVersion else {
            return nil
        }
        return payload
    }
}
