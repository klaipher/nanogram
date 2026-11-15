import Foundation
import CoreGraphics
import TelegramCore
import SwiftSignalKit
import BackgroundDiagnostics

/// Chooses where a PDF opens (see `PdfInlineViewingPolicy`). Hands free heap pages back, then reads the page count and size off the main queue.
func resolvePdfViewingRoute(path: String?, completion: @escaping (PdfViewingRoute) -> Void) {
    Queue.concurrentDefaultQueue().async {
        MemoryRelief.returnFreeHeapPages()
        var pageCount: Int?
        var fileSize: UInt64?
        if let path {
            let url = URL(fileURLWithPath: path)
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber {
                fileSize = size.uint64Value
            }
            if let document = CGPDFDocument(url as CFURL) {
                pageCount = document.numberOfPages
            }
        }
        let headroom = ProcessMemory.availableHeadroom()
        let route = PdfInlineViewingPolicy.route(pageCount: pageCount, fileSize: fileSize, headroom: headroom, budget: ProcessMemory.currentBudget())
        let headroomText = headroom.map { "\($0 / (1024 * 1024)) MB" } ?? "unknown"
        Logger.shared.log("PdfOpen", "Opening a PDF: headroom \(headroomText), pages \(pageCount.map(String.init) ?? "unknown"), size \(fileSize.map(String.init) ?? "unknown"), route \(route)")
        Queue.mainQueue().async {
            completion(route)
        }
    }
}
