import Foundation

/// Where the audio of the current route goes, read from the port types of `AVAudioSession.currentRoute.outputs`.
public enum AudioRouteDestination: Equatable {
    case headset
    case loudspeaker
    case receiver
    case other
}

/// The port type strings are the raw values of `AVAudioSession.Port` (`.headphones`, `.bluetoothA2DP`, `.bluetoothHFP`,
/// `.bluetoothLE`, `.builtInSpeaker`, `.builtInReceiver`). Strings keep this free of AVFoundation so it runs in host tests.
public func audioRouteDestination(outputPortTypes: [String]) -> AudioRouteDestination {
    let headsetTypes: Set<String> = ["Headphones", "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE"]
    if outputPortTypes.contains(where: { headsetTypes.contains($0) }) {
        return .headset
    }
    if outputPortTypes.contains("Speaker") {
        return .loudspeaker
    }
    if outputPortTypes.contains("Receiver") {
        return .receiver
    }
    return .other
}

/// Whether the route the session reports contradicts a request for the loudspeaker: no headset in the route, but the
/// audio is not on the loudspeaker either. A route with no outputs at all says nothing, the session is mid-change.
public func loudspeakerRequestMissedRoute(outputPortTypes: [String]) -> Bool {
    if outputPortTypes.isEmpty {
        return false
    }
    switch audioRouteDestination(outputPortTypes: outputPortTypes) {
    case .loudspeaker, .headset:
        return false
    case .receiver, .other:
        return true
    }
}
