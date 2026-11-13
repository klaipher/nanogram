import Foundation

/// A memory-limit kill reported by MetricKit (iOS 27 `MemoryExceptionDiagnostic`), shaped like a crash diagnostic so
/// it appears in the Crash Logs list.
public enum MemoryExceptionReport {
    public static let exceptionTitle = "Memory limit exceeded"

    /// `encodedDiagnostic` is the JSON of the MetricKit diagnostic (its call stack tree). Throws if it is not a JSON
    /// object.
    public static func input(encodedDiagnostic: Data, metadata: CrashReportMetadata) throws -> CrashReportInput {
        guard let object = try JSONSerialization.jsonObject(with: encodedDiagnostic) as? [String: Any] else {
            throw CocoaError(.coderInvalidValue)
        }
        var report: [String: Any] = [
            "isMemoryException": true,
            "diagnosticMetaData": [
                "exceptionType": exceptionTitle,
                "terminationReason": "The system ended the app because it used more memory than it is allowed"
            ]
        ]
        report["callStackTree"] = object["callStackTree"] ?? object
        return CrashReportInput(diagnosticJSON: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), metadata: metadata)
    }
}
