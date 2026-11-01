import Foundation

/// A frame as `AnimationCompressor` writes it, checked before anything is decoded into a texture.
///
/// Layout: magic, plane count (4), width, height, then per plane its width, height, row stride in
/// bytes, Huffman data length and the data. The planes are luma and alpha at full size and the two
/// chroma planes at half size, all whole 8x8 blocks of `Float32` coefficients. A frame read from a
/// cache file is not trusted: a plane whose size or stride does not match what the renderer's
/// textures hold, or whose data runs past the end, makes the whole frame invalid.
public struct CompressedImageLayout {
    public struct Plane {
        public let width: Int
        public let height: Int
        public let bytesPerRow: Int
        public let data: Data
    }

    public static let magic: Int32 = 0x543ee445

    public let width: Int
    public let height: Int
    public let planes: [Plane]

    /// Plane sizes for a frame of `width` x `height`, in plane order.
    public static func planeSizes(width: Int, height: Int) -> [(width: Int, height: Int)] {
        return [
            (width, height),
            (width / 2, height / 2),
            (width / 2, height / 2),
            (width, height)
        ]
    }

    public init?(data: Data) {
        var offset = 0
        func readInt32() -> Int? {
            guard offset >= 0, offset + 4 <= data.count else {
                return nil
            }
            var value: Int32 = 0
            withUnsafeMutableBytes(of: &value) { buffer in
                let _ = data.copyBytes(to: buffer, from: (data.startIndex + offset) ..< (data.startIndex + offset + 4))
            }
            offset += 4
            return Int(value)
        }

        guard let magic = readInt32(), magic == Int(CompressedImageLayout.magic) else {
            return nil
        }
        guard let planeCount = readInt32(), planeCount == 4 else {
            return nil
        }
        guard let width = readInt32(), let height = readInt32(), AnimationCompressor.canCompress(width: width, height: height) else {
            return nil
        }

        var planes: [Plane] = []
        for expectedSize in CompressedImageLayout.planeSizes(width: width, height: height) {
            guard let planeWidth = readInt32(), let planeHeight = readInt32(), let bytesPerRow = readInt32(), let planeSize = readInt32() else {
                return nil
            }
            guard planeWidth == expectedSize.width, planeHeight == expectedSize.height, bytesPerRow == planeWidth * 4 else {
                return nil
            }
            guard planeSize >= 0, planeSize <= data.count - offset else {
                return nil
            }
            let planeData = data.subdata(in: (data.startIndex + offset) ..< (data.startIndex + offset + planeSize))
            offset += planeSize
            planes.append(Plane(width: planeWidth, height: planeHeight, bytesPerRow: bytesPerRow, data: planeData))
        }

        self.width = width
        self.height = height
        self.planes = planes
    }
}
