import Foundation
import CoreVideo
import IOSurface

private let surfaceColorKeys: [CFString] = [
    "IOSurfaceYCbCrMatrix" as CFString,
    "IOSurfaceColorPrimaries" as CFString,
    "IOSurfaceTransferFunction" as CFString,
    "IOSurfaceColorSpace" as CFString,
    "IOSurfaceColorSpaceID" as CFString,
    "IOSurfaceICCProfile" as CFString,
    "IOSurfaceChromaLocationTopField" as CFString
]

func removeHardwareColorAttachments(_ pixelBuffer: CVPixelBuffer) {
    if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() {
        for key in surfaceColorKeys {
            IOSurfaceRemoveValue(surface, key)
        }
    }
    CVBufferRemoveAllAttachments(pixelBuffer)
}
