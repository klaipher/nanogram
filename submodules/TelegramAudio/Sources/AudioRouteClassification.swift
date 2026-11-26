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

/// Whether the loudspeaker the user chose is put back when CallKit hands the session back after an interruption (a phone
/// call, Siri, an alarm), which clears the override. Only while the audio is on the phone itself: a headset, a car or
/// AirPlay that took the route in the meantime keeps it. A route with no outputs yet is the phone's own.
public func loudspeakerShouldBeReappliedOnActivation(outputPortTypes: [String]) -> Bool {
    switch audioRouteDestination(outputPortTypes: outputPortTypes) {
    case .receiver, .loudspeaker:
        return true
    case .headset:
        return false
    case .other:
        return outputPortTypes.isEmpty
    }
}

/// Whether a loudspeaker request the session did not honour is tried once more, a moment later: only the first attempt,
/// only while no newer request replaced it, and only while the route still contradicts it (not a headset, not empty).
public func loudspeakerRequestShouldBeRetried(outputPortTypes: [String], attempt: Int, isLatestRequest: Bool) -> Bool {
    return attempt == 0 && isLatestRequest && loudspeakerRequestMissedRoute(outputPortTypes: outputPortTypes)
}

/// The ports of the phone itself (`.builtInMic`, `.builtInReceiver`, `.builtInSpeaker`): there is one of each, so the
/// type alone names them.
private let builtInAudioPortTypes: Set<String> = ["MicrophoneBuiltIn", "Receiver", "Speaker"]

/// A short tag that stays the same for one port across launches and tells two devices apart: the top 24 bits of the
/// FNV-1a 32-bit hash of its uid, as 6 hex digits. `hashValue` is seeded per process, so it cannot be used. The uid itself
/// is never logged, because for a Bluetooth port it holds the device's address.
public func audioPortLogTag(uid: String) -> String {
    var hash: UInt32 = 2166136261
    for byte in uid.utf8 {
        hash ^= UInt32(truncatingIfNeeded: byte)
        hash = hash &* 16777619
    }
    return String(format: "%06x", hash >> 8)
}

/// How a port appears in the logs: its type, plus the uid tag for a port that is not part of the phone. Never its name,
/// which is the one the user gave the device ("<first name>'s AirPods Pro"), because the audio session lines go to the
/// always-on critical log, which the report does not mask.
public func audioPortLogLabel(portType: String, uid: String) -> String {
    if builtInAudioPortTypes.contains(portType) {
        return portType
    }
    return "\(portType)#\(audioPortLogTag(uid: uid))"
}

/// The session writes its route each time the system says the route changed and each time it activates, often several
/// times in a few milliseconds with nothing different. Only a route that differs from the last one written is written.
public struct AudioRouteLogDeduplicator {
    private var lastLogged: String?

    public init() {
    }

    public mutating func shouldLog(_ description: String) -> Bool {
        if self.lastLogged == description {
            return false
        }
        self.lastLogged = description
        return true
    }
}
