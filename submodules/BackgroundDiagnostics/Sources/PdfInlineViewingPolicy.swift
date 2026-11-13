import Darwin

/// Where a PDF is shown.
public enum PdfViewingRoute: Sendable, Equatable {
    /// In the app's own PDF view (searchable, minimizable).
    case inline
    /// In the system document preview, which does the rendering and text recognition outside the app's memory budget.
    case quickLook
}

/// Decides whether a PDF may open in the app's own PDF view. PDFKit runs text recognition on embedded images inside
/// the app, and a one-page 200 KB receipt was enough to push an app that was already near its limit over it, so the
/// memory headroom decides for every document; file size and page count only add a second reason for large files.
public enum PdfInlineViewingPolicy {
    /// Below this much memory left (bytes) the app opens no PDF itself.
    public static let minimumHeadroom: UInt64 = 1_500 * 1024 * 1024
    /// A file at least this large (bytes) always goes to the system preview.
    public static let largeFileSize: UInt64 = 30 * 1024 * 1024
    /// A document with at least this many pages always goes to the system preview.
    public static let largePageCount = 300

    /// `headroom` is the memory the app may still allocate (`ProcessMemory.availableHeadroom()`), nil when unknown;
    /// an unknown headroom does not block the in-app view.
    public static func route(pageCount: Int?, fileSize: UInt64?, headroom: UInt64?) -> PdfViewingRoute {
        if let headroom, headroom < minimumHeadroom {
            return .quickLook
        }
        if let fileSize, fileSize >= largeFileSize {
            return .quickLook
        }
        if let pageCount, pageCount >= largePageCount {
            return .quickLook
        }
        return .inline
    }
}

extension ProcessMemory {
    /// How much more memory the app may use before the system ends it (`os_proc_available_memory`), nil where the
    /// system does not report it or reports zero.
    public static func availableHeadroom() -> UInt64? {
        #if os(iOS)
        let value = os_proc_available_memory()
        return value > 0 ? UInt64(value) : nil
        #else
        return nil
        #endif
    }
}
