import Foundation
import TelegramAudio

/// A route for the log without the port's name, which is the user's own device name.
func audioOutputLogName(_ output: AudioSessionOutput) -> String {
    switch output {
    case .builtin:
        return "builtin"
    case .speaker:
        return "speaker"
    case .headphones:
        return "headphones"
    case let .port(port):
        switch port.type {
        case .bluetooth:
            return "bluetooth"
        case .wired:
            return "wired"
        case .generic:
            return "port"
        }
    }
}
