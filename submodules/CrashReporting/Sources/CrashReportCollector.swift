import Foundation

#if os(iOS)
import MetricKit

/// Receives MetricKit reports. Crash diagnostics go to `CrashReportStore` (the Crash Logs list), as before; every
/// metric and diagnostic report is also kept in `MetricReportStore` for Debug Settings ▸ Send MetricKit Reports.
///
/// iOS 27 replaced the payload API with `MetricManager` (`MXMetricPayload` and `MXDiagnosticPayload` are marked
/// to-be-deprecated in the iOS 27 SDK). There the reports come from `MetricManager.metricReports` and
/// `diagnosticReports`; the `MXMetricManager` subscription stays only for the crash list, whose text rendering reads
/// the MXCrashDiagnostic JSON layout (memory-limit kills from `diagnosticReports` use the iOS 27 call stack tree
/// layout, which `MemoryExceptionReport` converts to it). iOS 15-26 store the MX payloads themselves.
public final class CrashReportCollector: NSObject, MXMetricManagerSubscriber {
    public static let shared = CrashReportCollector()
    private var started = false
    private var metricManager: AnyObject?
    private var metricTasks: [Task<Void, Never>] = []

    public func start() {
        precondition(Thread.isMainThread)
        guard !self.started else {
            return
        }
        self.started = true
        let manager = MXMetricManager.shared
        manager.add(self)
        let pastPayloads = manager.pastDiagnosticPayloads
        let pastMetricPayloads = manager.pastPayloads
        DispatchQueue.global(qos: .utility).async {
            self.didReceive(pastPayloads)
            self.didReceive(pastMetricPayloads)
        }
        if #available(iOS 27.0, *) {
            self.startMetricManager()
        }
    }

    @available(iOS 27.0, *)
    private func startMetricManager() {
        let metricManager = MetricManager()
        self.metricManager = metricManager
        self.metricTasks.append(Task.detached(priority: .utility) {
            for await report in metricManager.metricReports {
                CrashReportCollector.storeReport(report, kind: .metrics, intervalEnd: report.timeRange.end)
            }
        })
        self.metricTasks.append(Task.detached(priority: .utility) {
            for await report in metricManager.diagnosticReports {
                CrashReportCollector.storeReport(report, kind: .diagnostics, intervalEnd: report.timeRange.end)
                CrashReportCollector.storeMemoryException(report)
            }
        })
    }

    @available(iOS 27.0, *)
    private static func storeMemoryException(_ report: DiagnosticReport) {
        guard case let .memoryException(diagnostic) = report.result else {
            return
        }
        do {
            let environment = report.environment
            let metadata = CrashReportMetadata(
                applicationVersion: environment.applicationVersion,
                buildVersion: environment.applicationBuildVersion,
                osVersion: "\(environment.osVersion.platform) \(environment.osVersion.number) (\(environment.osVersion.buildNumber))",
                deviceType: environment.deviceType,
                architecture: environment.platformArchitecture
            )
            let input = try MemoryExceptionReport.input(encodedDiagnostic: JSONEncoder().encode(diagnostic), metadata: metadata)
            try CrashReportStore.shared.importDiagnostics([input], intervalStart: report.timeRange.start, intervalEnd: report.timeRange.end)
        } catch {
            NSLog("MetricKit: could not persist a memory exception (%@)", String(describing: type(of: error)))
        }
    }

    private static func storeReport<T: Encodable>(_ report: T, kind: MetricReportStore.Kind, intervalEnd: Date) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try MetricReportStore.shared.store(try encoder.encode(report), kind: kind, intervalEnd: intervalEnd)
        } catch {
            NSLog("MetricKit: could not store a %@ report (%@)", kind.rawValue, String(describing: type(of: error)))
        }
    }

    private static var usesMetricManager: Bool {
        if #available(iOS 27.0, *) {
            return true
        } else {
            return false
        }
    }

    public func didReceive(_ payloads: [MXMetricPayload]) {
        guard !CrashReportCollector.usesMetricManager else {
            return
        }
        for payload in payloads {
            do {
                try MetricReportStore.shared.store(payload.jsonRepresentation(), kind: .metrics, intervalEnd: payload.timeStampEnd)
            } catch {
                NSLog("MetricKit: could not store a metric payload (%@)", String(describing: type(of: error)))
            }
        }
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if !CrashReportCollector.usesMetricManager {
                do {
                    try MetricReportStore.shared.store(payload.jsonRepresentation(), kind: .diagnostics, intervalEnd: payload.timeStampEnd)
                } catch {
                    NSLog("MetricKit: could not store a diagnostic payload (%@)", String(describing: type(of: error)))
                }
            }
            let inputs = (payload.crashDiagnostics ?? []).map { diagnostic in
                return CrashReportInput(diagnosticJSON: diagnostic.jsonRepresentation(), metadata: CrashReportMetadata(
                    applicationVersion: diagnostic.applicationVersion,
                    buildVersion: diagnostic.metaData.applicationBuildVersion,
                    osVersion: diagnostic.metaData.osVersion,
                    deviceType: diagnostic.metaData.deviceType,
                    architecture: diagnostic.metaData.platformArchitecture
                ))
            }
            do {
                try CrashReportStore.shared.importDiagnostics(inputs, intervalStart: payload.timeStampBegin, intervalEnd: payload.timeStampEnd)
            } catch {
                NSLog("MetricKit: could not persist crash diagnostics (%@)", String(describing: type(of: error)))
            }
        }
    }
}
#endif
