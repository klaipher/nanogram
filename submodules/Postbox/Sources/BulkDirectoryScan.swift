import Foundation

// `enum vtype` from <sys/vnode.h> is not imported into Swift: VREG is 1.
private let vnodeTypeRegularFile: fsobj_type_t = 1

/// One directory entry as `lstat` would describe it (symlinks are not followed).
struct BulkDirectoryEntry {
    var name: String
    var isRegularFile: Bool
    var size: Int64
    var linkCount: UInt32
    var modificationTime: Int
}

/// Lists a directory with getattrlistbulk(2): name, type, size, link count and mtime for
/// many entries per system call, instead of one lstat per file. Returns nil when the call
/// is not supported, so the caller can fall back to lstat.
func bulkDirectoryEntries(path: String) -> [BulkDirectoryEntry]? {
    let fd = open(path, O_RDONLY | O_DIRECTORY)
    if fd < 0 {
        return nil
    }
    defer {
        close(fd)
    }

    var attrList = attrlist()
    attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(bitPattern: ATTR_CMN_NAME) | attrgroup_t(bitPattern: ATTR_CMN_OBJTYPE) | attrgroup_t(bitPattern: ATTR_CMN_MODTIME)
    attrList.fileattr = attrgroup_t(bitPattern: ATTR_FILE_LINKCOUNT) | attrgroup_t(bitPattern: ATTR_FILE_DATALENGTH)

    let bufferSize = 64 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
    defer {
        buffer.deallocate()
    }

    var result: [BulkDirectoryEntry] = []
    while true {
        let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
        if count < 0 {
            return nil
        }
        if count == 0 {
            break
        }
        var entryStart = buffer
        for _ in 0 ..< Int(count) {
            let entryLength = Int(entryStart.loadUnaligned(as: UInt32.self))
            if entryLength <= 0 {
                return nil
            }
            var field = entryStart.advanced(by: 4)

            let returned = field.loadUnaligned(as: attribute_set_t.self)
            field = field.advanced(by: MemoryLayout<attribute_set_t>.size)

            var name: String?
            if (returned.commonattr & attrgroup_t(bitPattern: ATTR_CMN_NAME)) != 0 {
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let namePointer = field.advanced(by: Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                name = String(cString: namePointer)
                field = field.advanced(by: MemoryLayout<attrreference_t>.size)
            }
            var objectType: fsobj_type_t = 0
            if (returned.commonattr & attrgroup_t(bitPattern: ATTR_CMN_OBJTYPE)) != 0 {
                objectType = field.loadUnaligned(as: fsobj_type_t.self)
                field = field.advanced(by: MemoryLayout<fsobj_type_t>.size)
            }
            var modificationTime: Int?
            if (returned.commonattr & attrgroup_t(bitPattern: ATTR_CMN_MODTIME)) != 0 {
                let value = field.loadUnaligned(as: timespec.self)
                modificationTime = Int(value.tv_sec)
                field = field.advanced(by: MemoryLayout<timespec>.size)
            }
            var linkCount: UInt32?
            if (returned.fileattr & attrgroup_t(bitPattern: ATTR_FILE_LINKCOUNT)) != 0 {
                linkCount = field.loadUnaligned(as: UInt32.self)
                field = field.advanced(by: 4)
            }
            var size: Int64?
            if (returned.fileattr & attrgroup_t(bitPattern: ATTR_FILE_DATALENGTH)) != 0 {
                size = field.loadUnaligned(as: Int64.self)
                field = field.advanced(by: 8)
            }

            if let name = name {
                let isRegularFile = objectType == vnodeTypeRegularFile
                if isRegularFile, let size = size, let linkCount = linkCount, let modificationTime = modificationTime {
                    result.append(BulkDirectoryEntry(name: name, isRegularFile: true, size: size, linkCount: linkCount, modificationTime: modificationTime))
                } else {
                    // Not a regular file, or attributes are missing: never a removal candidate.
                    result.append(BulkDirectoryEntry(name: name, isRegularFile: false, size: size ?? 0, linkCount: linkCount ?? 0, modificationTime: modificationTime ?? Int.max))
                }
            }

            entryStart = entryStart.advanced(by: entryLength)
        }
    }
    return result
}
