import Foundation
import OSLog
import WatchConnectivity
import WatchKit

/// The watch's end of the iPhone's "Send Report": answers its request with a fresh report, and hands the phone a
/// copy in the background so the report has a watch part even when the watch is not reachable at that moment.
/// The watch has no button of its own.
@MainActor
final class WatchReportSession: NSObject {
    static let shared = WatchReportSession()

    /// The watch's own numbers: this launch, and each feature flag since it last changed.
    static let energy = EnergyMonitor(
        title: "Apple Watch energy and CPU numbers (the watch app process only)",
        ledgerKey: "nanogram.watch.energyLedger",
        defaultStates: Dictionary(uniqueKeysWithValues: WatchFeature.allCases.map { ($0.rawValue, $0.defaultValue) }),
        states: { Dictionary(uniqueKeysWithValues: WatchFeature.allCases.map { ($0.rawValue, WatchFeatureFlags.isEnabled($0)) }) }
    )

    /// Spacing of the background copies; the system delivers them when the phone is near.
    static let transferInterval: TimeInterval = 30 * 60
    static let lastTransferKey = "nanogram.watch.lastReportTransfer"

    private let logger = Logger(watchCategory: "report")
    private let launchDate = Date()
    private let delegate = WatchReportSessionDelegate()
    private var started = false

    /// The context the energy numbers use, read where WatchKit allows it.
    static func currentContext() -> EnergyContext {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let level = device.batteryLevel
        let power: EnergyPowerState
        switch device.batteryState {
        case .unplugged: power = .unplugged
        case .charging: power = .charging
        case .full: power = .full
        default: power = .unknown
        }
        return EnergyContext(
            batteryPercent: level >= 0 ? Int((level * 100).rounded()) : nil,
            power: power,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: EnergyContext.thermalName(ProcessInfo.processInfo.thermalState)
        )
    }

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        Self.energy.start(context: Self.currentContext())
        delegate.provider = { @Sendable in await WatchReportSession.shared.currentPayloadData(maximumBytes: WatchReportMessage.maximumReplyBytes) }
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
    }

    /// The report as the phone expects it, cut to fit `maximumBytes` (the reply path passes the message cap).
    func currentPayloadData(maximumBytes: Int = WatchReportMessage.maximumBytes) -> Data? {
        let context = Self.currentContext()
        let energy = Self.energy.report(context: context)
        let log = WatchReportBuilder.logText(since: launchDate)
        let bundle = Bundle.main.infoDictionary
        let inputs = WatchReportInputs(
            created: Date(),
            appVersion: bundle?["CFBundleShortVersionString"] as? String ?? "?",
            buildNumber: bundle?[kCFBundleVersionKey as String] as? String ?? "?",
            bundleId: Bundle.main.bundleIdentifier ?? "?",
            osVersion: "\(WKInterfaceDevice.current().systemName) \(WKInterfaceDevice.current().systemVersion)",
            modelIdentifier: Self.hardwareIdentifier(),
            context: context,
            energyText: energy,
            logText: log.text,
            logNote: log.note
        )
        return WatchReportBuilder.payload(inputs).encoded(maximumBytes: maximumBytes)
    }

    /// Hands the phone a copy for the times the watch is out of reach. At most one every 30 minutes unless `force`.
    func scheduleTransfer(force: Bool = false) {
        guard started, WCSession.default.activationState == .activated else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastTransferKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) >= Self.transferInterval else { return }
        guard let data = currentPayloadData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("watch-report-\(Int(Date().timeIntervalSince1970)).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("report copy not written: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Only the newest copy is worth sending.
        for transfer in WCSession.default.outstandingFileTransfers {
            transfer.cancel()
        }
        WCSession.default.transferFile(url, metadata: [WatchReportMessage.fileMarkerKey: true])
        defaults.set(Date(), forKey: Self.lastTransferKey)
    }

    private static func hardwareIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.machine", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

final class WatchReportSessionDelegate: NSObject, WCSessionDelegate, @unchecked Sendable {
    var provider: (@Sendable () async -> Data?)?

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message[WatchReportMessage.requestKey] != nil, let provider else {
            replyHandler([:])
            return
        }
        let reply = ReplyBox(replyHandler)
        Task {
            if let data = await provider() {
                reply.send([WatchReportMessage.payloadKey: data])
            } else {
                reply.send([:])
            }
        }
    }
}

/// WatchConnectivity's reply handler is not Sendable; it is called once, from the task that answers.
private final class ReplyBox: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func send(_ reply: [String: Any]) {
        handler(reply)
    }
}
