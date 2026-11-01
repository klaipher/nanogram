import Foundation
import TelegramCore

// The VP9 probe and the decoder fallback write to the app log, which a test process has to set up.
let installTestLogger: Void = {
    let logger = Logger(rootPath: NSTemporaryDirectory(), basePath: NSTemporaryDirectory() + "/AnimatedStickerNodeTests-logs")
    logger.logToFile = false
    logger.logToConsole = false
    Logger.setSharedLogger(logger)
}()
