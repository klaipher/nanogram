#if os(macOS)
import Foundation
import TgVoipWebrtc
import TelegramCore
import HLSPlayback

public func broadcastPartSlice(_ data: Data) -> Data? {
    var info = BroadcastPartHeaderInfo()
    let parsed = data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
            return false
        }
        return BroadcastPartHeaderParse(base, raw.count, &info)
    }
    guard parsed, info.sliceOffset <= data.count, info.sliceOffset + info.sliceSize <= data.count else {
        return nil
    }
    let start = data.startIndex + info.sliceOffset
    return data.subdata(in: start ..< start + info.sliceSize)
}

public func broadcastNetworkClass(_ networkType: NetworkType) -> HLSNetworkClass {
    switch networkType {
    case .none:
        return HLSNetworkClass("none")
    case .wifi:
        return HLSNetworkClass("wifi")
    }
}
#endif
