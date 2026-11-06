import Foundation

/// Decodes UTF-8 bytes straight from their memory. `String(data: Data(bytes:count:), encoding: .utf8)` first copies
/// the bytes into a heap `Data`; for message text that is one allocation and one copy per message read. Invalid
/// input gives nil, as it does there. A leading byte order mark is handled by Foundation (it drops it), so such
/// input still takes the Foundation path.
enum StrictUTF8String {
    static func decode(_ bytes: UnsafePointer<UInt8>, count: Int) -> String? {
        if count <= 0 {
            return ""
        }
        if count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return String(data: Data(bytes: bytes, count: count), encoding: .utf8)
        }
        let buffer = UnsafeBufferPointer(start: bytes, count: count)
        let string = String(decoding: buffer, as: UTF8.self)
        if string.utf8.elementsEqual(buffer) {
            return string
        }
        return nil
    }

    static func decode(raw bytes: UnsafeRawPointer, count: Int) -> String? {
        return StrictUTF8String.decode(bytes.assumingMemoryBound(to: UInt8.self), count: count)
    }
}
