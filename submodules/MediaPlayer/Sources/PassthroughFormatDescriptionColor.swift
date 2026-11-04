import Foundation
import CoreMedia

enum PassthroughFormatDescriptionColor {
    private static let colorKeys: [CFString] = [
        kCMFormatDescriptionExtension_ColorPrimaries,
        kCMFormatDescriptionExtension_TransferFunction,
        kCMFormatDescriptionExtension_YCbCrMatrix,
        kCMFormatDescriptionExtension_FullRangeVideo,
        kCMFormatDescriptionExtension_BitsPerComponent,
        kCMFormatDescriptionExtension_GammaLevel,
        kCMFormatDescriptionExtension_MasteringDisplayColorVolume,
        kCMFormatDescriptionExtension_ContentLightLevelInfo
    ]

    static func avcParameterSets(_ avcC: Data) -> (sets: [Data], nalUnitHeaderLength: Int32)? {
        let bytes = [UInt8](avcC)
        guard bytes.count >= 7, bytes[0] == 1 else {
            return nil
        }
        let nalUnitHeaderLength = Int32((bytes[4] & 0x03) + 1)
        var offset = 5
        var sets: [Data] = []
        func readSets(count: Int) -> Bool {
            for _ in 0 ..< count {
                guard offset + 2 <= bytes.count else {
                    return false
                }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard length > 0, offset + length <= bytes.count else {
                    return false
                }
                sets.append(Data(bytes[offset ..< offset + length]))
                offset += length
            }
            return true
        }
        let spsCount = Int(bytes[offset] & 0x1f)
        offset += 1
        guard readSets(count: spsCount), offset < bytes.count else {
            return nil
        }
        let ppsCount = Int(bytes[offset])
        offset += 1
        guard readSets(count: ppsCount), !sets.isEmpty else {
            return nil
        }
        return (sets, nalUnitHeaderLength)
    }

    static func hevcParameterSets(_ hvcC: Data) -> (sets: [Data], nalUnitHeaderLength: Int32)? {
        let bytes = [UInt8](hvcC)
        guard bytes.count >= 23, bytes[0] == 1 else {
            return nil
        }
        let nalUnitHeaderLength = Int32((bytes[21] & 0x03) + 1)
        var offset = 22
        let arrayCount = Int(bytes[offset])
        offset += 1
        var sets: [Data] = []
        for _ in 0 ..< arrayCount {
            guard offset + 3 <= bytes.count else {
                return nil
            }
            offset += 1
            let count = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            for _ in 0 ..< count {
                guard offset + 2 <= bytes.count else {
                    return nil
                }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard length > 0, offset + length <= bytes.count else {
                    return nil
                }
                sets.append(Data(bytes[offset ..< offset + length]))
                offset += length
            }
        }
        return sets.isEmpty ? nil : (sets, nalUnitHeaderLength)
    }

    private static func description(parameterSets: (sets: [Data], nalUnitHeaderLength: Int32), hevc: Bool) -> CMFormatDescription? {
        let sets = parameterSets.sets
        let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer {
            buffers.forEach { $0.deallocate() }
        }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }
        var result: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: parameterSets.nalUnitHeaderLength, extensions: nil, formatDescriptionOut: &result)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: parameterSets.nalUnitHeaderLength, formatDescriptionOut: &result)
        }
        return status == noErr ? result : nil
    }

    static func apply(to extensions: NSMutableDictionary, avcC: Data) {
        guard let parameterSets = avcParameterSets(avcC), let derived = description(parameterSets: parameterSets, hevc: false) else {
            return
        }
        copyColor(from: derived, to: extensions)
    }

    static func apply(to extensions: NSMutableDictionary, hvcC: Data) {
        guard let parameterSets = hevcParameterSets(hvcC), let derived = description(parameterSets: parameterSets, hevc: true) else {
            return
        }
        copyColor(from: derived, to: extensions)
    }

    private static func copyColor(from derived: CMFormatDescription, to extensions: NSMutableDictionary) {
        for key in colorKeys {
            if let value = CMFormatDescriptionGetExtension(derived, extensionKey: key) {
                extensions.setObject(value, forKey: key as NSString)
            }
        }
        if let depth = CMFormatDescriptionGetExtension(derived, extensionKey: kCMFormatDescriptionExtension_Depth) {
            extensions.setObject(depth, forKey: kCMFormatDescriptionExtension_Depth as NSString)
        }
    }
}
