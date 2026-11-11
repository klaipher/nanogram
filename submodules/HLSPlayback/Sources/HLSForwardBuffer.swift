import Foundation

// How many seconds ahead of the playhead the player keeps buffered. A muted video playing inline in a chat bubble is
// often scrolled past or never unmuted, so it holds a short window (fewer bytes fetched and parts held); a video with
// sound, in the gallery or fullscreen, holds hls.js's 60 s.
public let hlsForwardBufferInlineMutedSeconds: Double = 15.0
public let hlsForwardBufferFullSeconds: Double = 60.0

public func hlsForwardBufferSeconds(isMuted: Bool, isInline: Bool) -> Double {
    return isMuted && isInline ? hlsForwardBufferInlineMutedSeconds : hlsForwardBufferFullSeconds
}
