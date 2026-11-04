import Foundation

/// One-line records about why a call ended, written to the always-on short (critical) log so a tester's
/// export names the cause without "Log to File". Ids only: no names, numbers, keys or hashes.
public enum CallDiagnostics {
    public static func log(_ what: @autoclosure () -> String) {
        Logger.shared.shortLog("Call", what())
    }

    /// "drop call <id> in <state> as <reason> from <file>:<line>"
    static func dropLine(callId: Int64?, state: String, reason: String, file: String, line: Int) -> String {
        let id = callId.map { String($0) } ?? "-"
        return "drop call \(id) in \(state) as \(reason) from \(callSite(file: file, line: line))"
    }

    /// "Module/File.swift" and the line, without the build path.
    static func callSite(file: String, line: Int) -> String {
        let name = file.split(separator: "/").last.map(String.init) ?? file
        return "\(name):\(line)"
    }

    /// "call <id> on build <n>"
    static func buildLine(callId: Int64?, build: String?) -> String {
        return "call \(callId.map { String($0) } ?? "-") on build \(build ?? "?")"
    }

    static func currentBuild() -> String? {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    /// An RPC error as "CODE_NAME" without the numeric code and any free text after it.
    static func rpcErrorName(code: Int32, description: String) -> String {
        let name = description.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        return name.isEmpty ? "rpc \(code)" : "rpc \(code) \(name)"
    }

    /// "reason hangup, flags 0x4": the discard reason the server gave (nil when it gave none) and the raw flags.
    static func discardDescription(reason: String?, flags: Int32) -> String {
        return "reason \(reason ?? "none"), flags 0x\(String(UInt32(bitPattern: flags), radix: 16))"
    }
}
