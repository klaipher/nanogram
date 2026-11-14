import Foundation

public func readMediaFileData(path: String, complete: Bool) -> Data? {
    return try? Data(contentsOf: URL(fileURLWithPath: path), options: complete ? .mappedIfSafe : [])
}
