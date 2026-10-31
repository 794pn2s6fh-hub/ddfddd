//
//  FileItemHelpers.swift
//  Filos
//
//  Created by lunginspector on 8/1/26.
//

import Foundation
import Darwin
import UniformTypeIdentifiers

struct FileItem: Identifiable {
    let id = UUID()
    var name: String
    var fileURL: URL
    var destURL: URL
    var type: FileType
    var uttype: UTType
    var size: Int
    var creationDate: Date
    var modifiedDate: Date
    var creationDateStr: String
    var modifiedDateStr: String
    
    var hidden: Bool
    var posixPerms: String
    var owner: String
    var group: String
    var readable: Bool
    var writable: Bool
    var executable: Bool
}

let clearFileItem = FileItem(name: "", fileURL: URL(fileURLWithPath: ""), destURL: URL(fileURLWithPath: ""), type: .file, uttype: .data, size: 0, creationDate: Date(), modifiedDate: Date(), creationDateStr: "", modifiedDateStr: "", hidden: false, posixPerms: "", owner: "", group: "", readable: false, writable: false, executable: false)

func getFileItem(at url: URL, isContainer: Bool = false) -> FileItem {
    var item = FileItem(name: url.lastPathComponent, fileURL: url, destURL: url, type: .file, uttype: .data, size: 0, creationDate: Date(), modifiedDate: Date(), creationDateStr: "", modifiedDateStr: "", hidden: false, posixPerms: "", owner: "", group: "", readable: false, writable: false, executable: false)
    
    if isContainer {
        if let folderName = folderLabel(url: url) {
            item.name = folderName
        }
    }
    
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd-yyyy h:mm a"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey, .isHiddenKey]
    if let values = try? url.resourceValues(forKeys: keys) {
        if values.isSymbolicLink ?? false {
            if let path = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                item.destURL = URL(fileURLWithPath: path)
            }
        }
        if let symlink = values.isSymbolicLink, let directory = values.isDirectory {
            item.type = symlink ? .symlink : directory ? .folder : .file
        }
        item.uttype = values.contentType ?? .data
        item.size = values.fileSize ?? 0
        if let date = values.creationDate {
            item.creationDate = date
            item.creationDateStr = formatter.string(from: date)
        } else {
            item.creationDateStr = ""
        }
        if let date = values.contentModificationDate {
            item.modifiedDate = date
            item.modifiedDateStr = formatter.string(from: date)
        } else {
            item.modifiedDateStr = ""
        }
        item.hidden = values.isHidden ?? false
    }
    if let attrs = try? fm.attributesOfItem(atPath: url.path) {
        if item.size == 0, let size = attrs[.size] as? NSNumber {
            item.size = max(0, size.intValue)
        }
        if let perms = attrs[.posixPermissions] as? NSNumber {
            item.posixPerms = String(format: "%04o", perms.intValue)
        }
        if let owner = attrs[.ownerAccountName] as? String {
            item.owner = owner
        }
        if let group = attrs[.groupOwnerAccountName] as? String {
            item.group = group
        }
    }
    item.readable = fm.isReadableFile(atPath: url.path)
    item.writable = fm.isWritableFile(atPath: url.path)
    item.executable = fm.isExecutableFile(atPath: url.path)
    
    return item
}

enum FileType: String {
    case file, folder, symlink
    
    var sortOrder: Int {
        switch self {
        case .file: return 0
        case .symlink: return 1
        case .folder: return 2
        }
    }
}

private func getContainerFiles(at url: URL) -> [FileItem] {
    var files: [FileItem] = []
    let paths = fsHandlers.getDirPaths(url.path)
    for path in paths {
        files.append(getFileItem(at: URL(fileURLWithPath: path)))
    }
    return files
}


/// Calculates the aggregate size of a readable directory tree. The calculation
/// runs only when Folder Info is opened, not while populating directory rows.
/// Symlinks and special filesystem entries are not followed or counted.
enum FolderContentSizeReader {
    private static let maximumDepth = 64
    private static let maximumEntries = 200_000

    static func calculate(at url: URL) throws -> Int64 {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }

        var rootStat = stat()
        guard fstat(fd, &rootStat) == 0 else { throw posixError() }
        guard (rootStat.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFDIR) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        var visitedEntries = 0
        return try directorySize(fileDescriptor: fd, depth: 0, visitedEntries: &visitedEntries)
    }

    private static func directorySize(fileDescriptor: Int32, depth: Int, visitedEntries: inout Int) throws -> Int64 {
        guard depth <= maximumDepth else { throw CocoaError(.fileReadTooLarge) }
        let duplicateFD = dup(fileDescriptor)
        guard duplicateFD >= 0 else { throw posixError() }
        guard let directory = fdopendir(duplicateFD) else {
            close(duplicateFD)
            throw posixError()
        }
        defer { closedir(directory) }

        let directoryFD = dirfd(directory)
        var total: Int64 = 0

        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw posixError() }
                break
            }

            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }

            visitedEntries += 1
            guard visitedEntries <= maximumEntries else { throw CocoaError(.fileReadTooLarge) }

            var childStat = stat()
            let statResult = name.withCString {
                fstatat(directoryFD, $0, &childStat, AT_SYMLINK_NOFOLLOW)
            }
            guard statResult == 0 else { throw posixError() }

            let kind = childStat.st_mode & mode_t(Darwin.S_IFMT)
            if kind == mode_t(Darwin.S_IFLNK) {
                continue
            } else if kind == mode_t(Darwin.S_IFDIR) {
                let childFD = name.withCString {
                    openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard childFD >= 0 else { throw posixError() }
                defer { close(childFD) }

                var openedStat = stat()
                guard fstat(childFD, &openedStat) == 0,
                      (openedStat.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFDIR) else {
                    throw posixError()
                }
                let childSize = try directorySize(fileDescriptor: childFD, depth: depth + 1, visitedEntries: &visitedEntries)
                let (sum, overflow) = total.addingReportingOverflow(childSize)
                guard !overflow else { throw CocoaError(.fileReadTooLarge) }
                total = sum
            } else if kind == mode_t(Darwin.S_IFREG) {
                let childFD = name.withCString {
                    openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard childFD >= 0 else { throw posixError() }
                defer { close(childFD) }

                var openedStat = stat()
                guard fstat(childFD, &openedStat) == 0,
                      (openedStat.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFREG),
                      openedStat.st_size >= 0 else {
                    throw posixError()
                }
                let (sum, overflow) = total.addingReportingOverflow(Int64(openedStat.st_size))
                guard !overflow else { throw CocoaError(.fileReadTooLarge) }
                total = sum
            }
            // Other special entries (sockets, devices, FIFOs) contribute no file data.
        }

        return total
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
