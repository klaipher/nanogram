import Foundation
import CoreMedia
import FFMpegBinding

public final class FFMpegMediaFrameSourceContextHelpers {
    public static let registerFFMpegGlobals: Void = {
        FFMpegGlobals.initializeGlobals()
        return
    }()
    
    static func createFormatDescriptionFromAVCCodecData(_ formatId: UInt32, _ width: Int32, _ height: Int32, _ extradata: Data) -> CMFormatDescription? {
        let par = NSMutableDictionary()
        par.setObject(1 as NSNumber, forKey: "HorizontalSpacing" as NSString)
        par.setObject(1 as NSNumber, forKey: "VerticalSpacing" as NSString)
        
        let atoms = NSMutableDictionary()
        atoms.setObject(extradata as NSData, forKey: "avcC" as NSString)
        
        let extensions = NSMutableDictionary()
        extensions.setObject("left" as NSString, forKey: "CVImageBufferChromaLocationBottomField" as NSString)
        extensions.setObject("left" as NSString, forKey: "CVImageBufferChromaLocationTopField" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "FullRangeVideo" as NSString)
        extensions.setObject(par, forKey: "CVPixelAspectRatio" as NSString)
        extensions.setObject(atoms, forKey: "SampleDescriptionExtensionAtoms" as NSString)
        extensions.setObject("avc1" as NSString, forKey: "FormatName" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "SpatialQuality" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "Version" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "FullRangeVideo" as NSString)
        extensions.setObject(1 as NSNumber, forKey: "CVFieldCount" as NSString)
        extensions.setObject(24 as NSNumber, forKey: "Depth" as NSString)
        PassthroughFormatDescriptionColor.apply(to: extensions, avcC: extradata)
        
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: CMVideoCodecType(formatId), width: width, height: height, extensions: extensions, formatDescriptionOut: &formatDescription)
        
        return formatDescription
    }
    
    // FFmpeg's extradata for MPEG-4 Part 2 is the raw VOS/VOL header (it starts with a 00 00 01 start
    // code), but the esds atom must hold an ES descriptor around it. With the raw bytes VideoToolbox
    // refused the format (-12909), so these videos (some GIFs) showed one frame and never played.
    private static func mpeg4EsdsAtom(codecData: Data) -> Data {
        let bytes = [UInt8](codecData)
        guard bytes.count >= 3, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0x01 else {
            return codecData
        }
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            let length = body.count
            return [tag, 0x80 | UInt8((length >> 21) & 0x7f), 0x80 | UInt8((length >> 14) & 0x7f), 0x80 | UInt8((length >> 7) & 0x7f), UInt8(length & 0x7f)] + body
        }
        // objectTypeIndication 0x20 (MPEG-4 Visual), streamType 0x11 (visual); buffer size and bitrates unknown.
        let decoderConfig = descriptor(0x04, [0x20, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] + descriptor(0x05, bytes))
        let esDescriptor = descriptor(0x03, [0x00, 0x01, 0x00] + decoderConfig + descriptor(0x06, [0x02]))
        // Full-box version and flags.
        return Data([0x00, 0x00, 0x00, 0x00] + esDescriptor)
    }

    static func createFormatDescriptionFromMpeg4CodecData(_ formatId: UInt32, _ width: Int32, _ height: Int32, _ extradata: Data) -> CMFormatDescription? {
        let par = NSMutableDictionary()
        par.setObject(1 as NSNumber, forKey: "HorizontalSpacing" as NSString)
        par.setObject(1 as NSNumber, forKey: "VerticalSpacing" as NSString)
        
        let atoms = NSMutableDictionary()
        atoms.setObject(mpeg4EsdsAtom(codecData: extradata) as NSData, forKey: "esds" as NSString)
        
        let extensions = NSMutableDictionary()
        extensions.setObject("left" as NSString, forKey: "CVImageBufferChromaLocationBottomField" as NSString)
        extensions.setObject("left" as NSString, forKey: "CVImageBufferChromaLocationTopField" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "FullRangeVideo" as NSString)
        extensions.setObject(par, forKey: "CVPixelAspectRatio" as NSString)
        extensions.setObject(atoms, forKey: "SampleDescriptionExtensionAtoms" as NSString)
        extensions.setObject("mp4v" as NSString, forKey: "FormatName" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "SpatialQuality" as NSString)
        //extensions.setObject(0 as NSNumber, forKey: "Version" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "FullRangeVideo" as NSString)
        extensions.setObject(1 as NSNumber, forKey: "CVFieldCount" as NSString)
        extensions.setObject(24 as NSNumber, forKey: "Depth" as NSString)
        
        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_MPEG4Video, width: width, height: height, extensions: extensions, formatDescriptionOut: &formatDescription) == noErr else {
            return nil
        }
        
        return formatDescription
    }
    
    static func createFormatDescriptionFromHEVCCodecData(_ formatId: UInt32, _ width: Int32, _ height: Int32, _ extradata: Data) -> CMFormatDescription? {
        let par = NSMutableDictionary()
        par.setObject(1 as NSNumber, forKey: "HorizontalSpacing" as NSString)
        par.setObject(1 as NSNumber, forKey: "VerticalSpacing" as NSString)
        
        let atoms = NSMutableDictionary()
        atoms.setObject(extradata as NSData, forKey: "hvcC" as NSString)
        
        let extensions = NSMutableDictionary()
        extensions.setObject("left" as NSString, forKey: "CVImageBufferChromaLocationBottomField" as NSString)
        extensions.setObject("left" as NSString, forKey: "CVImageBufferChromaLocationTopField" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "FullRangeVideo" as NSString)
        extensions.setObject(par, forKey: "CVPixelAspectRatio" as NSString)
        extensions.setObject(atoms, forKey: "SampleDescriptionExtensionAtoms" as NSString)
        extensions.setObject("hevc" as NSString, forKey: "FormatName" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "SpatialQuality" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "Version" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "FullRangeVideo" as NSString)
        extensions.setObject(1 as NSNumber, forKey: "CVFieldCount" as NSString)
        extensions.setObject(24 as NSNumber, forKey: "Depth" as NSString)
        PassthroughFormatDescriptionColor.apply(to: extensions, hvcC: extradata)
        
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: CMVideoCodecType(formatId), width: width, height: height, extensions: extensions, formatDescriptionOut: &formatDescription)
        
        return formatDescription
    }
    
    static func createFormatDescriptionFromAV1CodecData(_ formatId: UInt32, _ width: Int32, _ height: Int32, _ extradata: Data, frameData: Data) -> CMFormatDescription? {
        return nil
        
        /*let par = NSMutableDictionary()
        par.setObject(1 as NSNumber, forKey: "HorizontalSpacing" as NSString)
        par.setObject(1 as NSNumber, forKey: "VerticalSpacing" as NSString)
        
        let atoms = NSMutableDictionary()
        atoms.setObject(extradata as NSData, forKey: "av1C" as NSString)
        
        let extensions = NSMutableDictionary()
        extensions.setObject("left" as NSString, forKey: "CVImageBufferChromaLocationBottomField" as NSString)
        extensions.setObject("left" as NSString, forKey: "CVImageBufferChromaLocationTopField" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "FullRangeVideo" as NSString)
        extensions.setObject(par, forKey: "CVPixelAspectRatio" as NSString)
        extensions.setObject(atoms, forKey: "SampleDescriptionExtensionAtoms" as NSString)
        extensions.setObject("hevc" as NSString, forKey: "FormatName" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "SpatialQuality" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "Version" as NSString)
        extensions.setObject(0 as NSNumber, forKey: "FullRangeVideo" as NSString)
        extensions.setObject(1 as NSNumber, forKey: "CVFieldCount" as NSString)
        extensions.setObject(24 as NSNumber, forKey: "Depth" as NSString)
        
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: CMVideoCodecType(formatId), width: width, height: height, extensions: extensions, formatDescriptionOut: &formatDescription)
        
        return formatDescription*/
    }
}

public enum MediaPlayerAudioFormat {
    #if os(macOS)
    public static let sampleRate: Int = 48000
    #else
    public static let sampleRate: Int = 44100
    #endif
    public static let channelCount: Int = 2
}

extension FFMpegMediaFrameSourceContextHelpers {
    static func makeAudioDecoder(codecContext: FFMpegAVCodecContext) -> FFMpegAudioFrameDecoder {
        return FFMpegAudioFrameDecoder(codecContext: codecContext, sampleRate: MediaPlayerAudioFormat.sampleRate, channelCount: MediaPlayerAudioFormat.channelCount)
    }
}
