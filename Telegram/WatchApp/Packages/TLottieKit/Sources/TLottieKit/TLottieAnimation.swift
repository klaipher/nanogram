import CoreGraphics
import Foundation
import TLottieCore

/// One parsed Lottie animation, rendered by tlottie (the C API in `tlottie.h`, the same library and call
/// sequence as the phone's `TLottieAnimation.mm`). Owns the per-animation memory; releasing the object frees it.
/// An instance is single-threaded (tlottie has no locks): use it from one task at a time.
public final class TLottieAnimation {
    /// `TLOTTIE_CHANNEL_BGRA`: 0xAARRGGBB words, [B, G, R, A] bytes. That is what a premultiplied-first,
    /// little-endian CGBitmap describes, so CoreGraphics reads the pixels without a swizzle pass. The default
    /// (RGBA) would swap red and blue and fail in no other way.
    private static let channelOrderBGRA: UInt32 = 1
    /// `TLOTTIE_FITZ_NONE`.
    private static let fitzNone: UInt32 = 0

    private let handle: OpaquePointer

    public let dimensions: CGSize
    public let frameCount: Int
    public let frameRate: Int
    public let duration: TimeInterval

    /// Inflates a TGS (gzipped Lottie JSON) file and parses it. Nil for anything that is not a valid,
    /// in-limits animation (also for raw JSON and dotLottie archives: stickers are gzipped JSON).
    public convenience init?(tgsFileURL url: URL) {
        guard let gzipped = try? Data(contentsOf: url),
              let json = try? decompressTgs(gzipped) else {
            return nil
        }
        self.init(jsonData: json)
    }

    /// Parses inflated Lottie JSON. Defensive caps mirror Telegram-iOS and the earlier rlottie wrapper: width or
    /// height above 1536 px, a frame rate above 360 and a duration above 9 s are refused (malformed or abusive input).
    public init?(jsonData: Data) {
        guard !jsonData.isEmpty else { return nil }
        let created: OpaquePointer? = jsonData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return tlottie_new_with_options(
                base,
                raw.count,
                Self.fitzNone,
                nil, 0,
                nil, 0,
                Self.channelOrderBGRA
            )
        }
        guard let created else { return nil }

        let rawFrameCount = Int(tlottie_frame_count(created))
        let rawFrameRate = tlottie_frame_rate(created)
        let width = Int(tlottie_width(created))
        let height = Int(tlottie_height(created))

        guard rawFrameRate.isFinite, rawFrameRate <= 360,
              width <= 1536, height <= 1536 else {
            tlottie_drop(created)
            return nil
        }
        let duration = rawFrameRate > 0 ? Double(rawFrameCount) / Double(rawFrameRate) : 0
        guard duration <= 9.0 else {
            tlottie_drop(created)
            return nil
        }

        self.handle = created
        self.frameCount = max(1, rawFrameCount)
        self.frameRate = max(1, Int(rawFrameRate))
        self.duration = duration
        self.dimensions = CGSize(width: max(1, width), height: max(1, height))
    }

    deinit {
        tlottie_drop(handle)
    }

    /// Renders frame `index` into a fresh CGImage sized `size × scale`. Returns nil if the size is degenerate,
    /// allocation fails or tlottie reports an error. The pixels are owned by a `Data` retained by the CGDataProvider.
    public func renderFrame(index: Int, size: CGSize, scale: CGFloat) -> CGImage? {
        let pixelWidth = max(1, Int(size.width * scale))
        let pixelHeight = max(1, Int(size.height * scale))
        // Same bound as the parse caps: nothing on the watch needs more, and it keeps the arithmetic below small.
        guard pixelWidth <= 4096, pixelHeight <= 4096 else { return nil }
        let bytesPerRow = pixelWidth * 4
        let pixelCount = pixelWidth * pixelHeight

        var pixels = [UInt32](repeating: 0, count: pixelCount)
        let status = pixels.withUnsafeMutableBufferPointer { buffer -> Int32 in
            // tlottie clears the buffer first and has no stride parameter: it writes tightly packed rows,
            // which is exactly the layout of the CGImage below.
            tlottie_render(
                handle,
                Float(index),
                UInt32(pixelWidth),
                UInt32(pixelHeight),
                buffer.baseAddress,
                pixelCount,
                1
            )
        }
        guard status == 0 else { return nil }  // TLOTTIE_OK

        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
