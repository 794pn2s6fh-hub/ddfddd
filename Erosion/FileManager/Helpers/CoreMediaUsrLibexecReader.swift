import Foundation
import Darwin
import CoreFoundation
import UniformTypeIdentifiers

/// Read-only, in-memory directory provider for /usr/libexec. Directory entries
/// and file bytes are obtained on demand through the CoreMedia bytestream XPC flow;
/// no filesystem copy is written.
enum CoreMediaUsrLibexecReader {
    static let remotePath = "/usr/libexec"

    private static let sessionLock = NSRecursiveLock()
    // A single root listing is shared by launch warm-up, initial navigation and
    // every later pull-to-refresh during this Erosion process.
    private static let rootCacheCondition = NSCondition()
    private static var didStart = false
    private static var rootLoadAttempted = false
    private static var rootLoadInProgress = false
    private static var cachedRootEntries: [FileItem]?
    private static var cachedRootError: Error?

    // Info-only size cache for virtual /usr/libexec directories. Successful
    // totals live in memory for this app process; directory listings and file
    // reads are deliberately not cached by this mechanism.
    private static let infoSizeCacheCondition = NSCondition()
    private static var cachedInfoDirectorySizes: [String: Int64] = [:]
    private static var infoDirectorySizesInProgress: Set<String> = []

    static func containsVirtualPath(_ url: URL) -> Bool {
        containsVirtualPath(url.standardizedFileURL.path)
    }

    static func containsVirtualPath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return normalized == remotePath || normalized.hasPrefix(remotePath + "/")
    }

    static func isRootPath(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == remotePath
    }

    /// Starts one CoreMedia root listing at app launch. The result remains in
    /// memory for the lifetime of this process; refresh gestures reuse it.
    static func startAtLaunch() {
        rootCacheCondition.lock()
        guard !didStart else {
            rootCacheCondition.unlock()
            return
        }
        didStart = true
        // Preview files are disposable working copies only. Remove leftovers from
        // an interrupted previous run before any new virtual file is opened.
        let stalePreviewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ErosionVirtualPreviews", isDirectory: true)
        try? FileManager.default.removeItem(at: stalePreviewDirectory)

        guard !rootLoadAttempted, !rootLoadInProgress else {
            rootCacheCondition.unlock()
            return
        }
        rootLoadAttempted = true
        rootLoadInProgress = true
        rootCacheCondition.unlock()

        DispatchQueue.global(qos: .utility).async {
            do {
                let entries = try listDirectoryUncached(at: remotePath)
                rootCacheCondition.lock()
                cachedRootEntries = entries
                rootLoadInProgress = false
                rootCacheCondition.broadcast()
                rootCacheCondition.unlock()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .erosionUsrLibexecDirectoryReady, object: nil)
                }
            } catch {
                rootCacheCondition.lock()
                cachedRootError = error
                rootLoadInProgress = false
                rootCacheCondition.broadcast()
                rootCacheCondition.unlock()
                // Keep the failure until the next explicit root navigation;
                // listDirectory(at:) clears it and retries with a fresh session.
                print("[libexec] CoreMedia initialization failed: \(error.localizedDescription)")
            }
        }
    }

    static func listDirectory(at url: URL) throws -> [FileItem] {
        let path = url.standardizedFileURL.path
        try validateVirtualPath(path)
        guard path == remotePath else {
            return try listDirectoryUncached(at: path)
        }

        // Use a condition to coalesce launch warm-up and first navigation. Once
        // a successful root snapshot exists, do not scan /usr/libexec again until
        // Erosion is completely relaunched.
        rootCacheCondition.lock()
        while rootLoadInProgress {
            rootCacheCondition.wait()
        }
        if let cachedRootEntries {
            rootCacheCondition.unlock()
            return cachedRootEntries
        }
        if cachedRootError != nil {
            // A launch-time XPC/CoreMedia failure can be a transient startup race.
            // Retry on the next explicit navigation instead of requiring a relaunch.
            cachedRootError = nil
            rootLoadAttempted = false
        }
        guard !rootLoadAttempted else {
            rootCacheCondition.unlock()
            throw CoreMediaReaderError.coreMediaUnavailable
        }
        rootLoadAttempted = true
        rootLoadInProgress = true
        rootCacheCondition.unlock()

        do {
            let entries = try listDirectoryUncached(at: path)
            rootCacheCondition.lock()
            cachedRootEntries = entries
            rootLoadInProgress = false
            rootCacheCondition.broadcast()
            rootCacheCondition.unlock()
            return entries
        } catch {
            rootCacheCondition.lock()
            cachedRootError = error
            rootLoadInProgress = false
            rootCacheCondition.broadcast()
            rootCacheCondition.unlock()
            throw error
        }
    }

    static func canReadDirectory(at url: URL) -> Bool {
        guard containsVirtualPath(url) else { return false }
        return (try? listDirectory(at: url)) != nil
    }

    static func isDirectory(at url: URL) -> Bool {
        guard containsVirtualPath(url) else { return false }
        do {
            return try withRetryingSession(at: url.standardizedFileURL.path) { session in
                try session.itemKind(at: url.standardizedFileURL.path, directoryHint: true) == .directory
            }
        } catch {
            return false
        }
    }

    static func canReadFile(at url: URL) -> Bool {
        guard containsVirtualPath(url) else { return false }
        do {
            return try withRetryingSession(at: url.standardizedFileURL.path) { session in
                try session.itemKind(at: url.standardizedFileURL.path, directoryHint: false) == .regularFile
            }
        } catch {
            return false
        }
    }

    static func rootFolderItem() -> FileItem {
        rootFolderItem(at: URL(fileURLWithPath: remotePath, isDirectory: true))
    }

    static func rootFolderItem(at url: URL) -> FileItem {
        let path = url.standardizedFileURL.path
        do {
            return try withRetryingSession(at: path) { session in
                try session.fileItem(at: path)
            }
        } catch {
            return makeFolderItem(at: url)
        }
    }

    static let reopenAppMessage = "CoreMedia lost its connection to a virtual system directory. Please close Erosion completely and open it again."

    /// Show the relaunch hint for an interrupted CoreMedia service/session, not
    /// for ordinary missing files or unsupported file types.
    static func shouldSuggestAppReopen(for error: Error, at url: URL) -> Bool {
        guard containsVirtualPath(url), let readerError = error as? CoreMediaReaderError else {
            return false
        }
        switch readerError {
        case .connectionInterrupted:
            return true
        case .xpcUnavailable, .memoryOriginHandshakeFailed, .coreMediaUnavailable:
            return true
        case .couldNotOpenPath(let failedPath):
            let requestedPath = url.standardizedFileURL.path
            return failedPath == requestedPath && requestedPath == remotePath
        default:
            return false
        }
    }

    /// Returns the aggregate byte size of all readable regular files below a
    /// virtual directory. Directory inode sizes are intentionally never used.
    /// A failure anywhere aborts the total so Info never displays a partial size.
    static func directoryContentSize(atPath path: String) throws -> Int64 {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateVirtualPath(normalized)
        return try withRetryingSession(at: normalized) { session in
            try session.directoryContentSize(at: normalized)
        }
    }

    /// Info-only variant: calculate a virtual directory size once, then reuse
    /// the successful total for later Info presentations during this process.
    /// It does not cache file data or directory listings and never writes to disk.
    static func cachedInfoDirectoryContentSize(atPath path: String) throws -> Int64 {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateVirtualPath(normalized)

        infoSizeCacheCondition.lock()
        while infoDirectorySizesInProgress.contains(normalized) {
            infoSizeCacheCondition.wait()
            if let cached = cachedInfoDirectorySizes[normalized] {
                infoSizeCacheCondition.unlock()
                return cached
            }
        }
        if let cached = cachedInfoDirectorySizes[normalized] {
            infoSizeCacheCondition.unlock()
            return cached
        }
        infoDirectorySizesInProgress.insert(normalized)
        infoSizeCacheCondition.unlock()

        do {
            let calculated = try directoryContentSize(atPath: normalized)
            infoSizeCacheCondition.lock()
            cachedInfoDirectorySizes[normalized] = calculated
            infoDirectorySizesInProgress.remove(normalized)
            infoSizeCacheCondition.broadcast()
            infoSizeCacheCondition.unlock()
            return calculated
        } catch {
            infoSizeCacheCondition.lock()
            infoDirectorySizesInProgress.remove(normalized)
            infoSizeCacheCondition.broadcast()
            infoSizeCacheCondition.unlock()
            throw error
        }
    }

    /// Reads one file into memory. No local URL, cache file, or temporary file is created.
    static func readFileData(atPath path: String, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateVirtualPath(normalized)
        return try withRetryingSession(at: normalized) { session in
            try session.readFileData(at: normalized, maximumBytes: maximumBytes)
        }
    }

    /// Materializes a virtual CoreMedia directory into a caller-owned temporary location.
    /// Symlinks are recreated as links and are never traversed during the export.
    static func copyDirectoryToLocal(
        atPath path: String,
        to destinationURL: URL,
        bestEffortUnreadableEntries: Bool = false
    ) throws {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        try validateVirtualPath(normalized)
        try copyDirectoryToLocal(
            atPath: normalized,
            to: destinationURL,
            depth: 0,
            bestEffortUnreadableEntries: bestEffortUnreadableEntries
        )
    }

    private static func copyDirectoryToLocal(
        atPath path: String,
        to destinationURL: URL,
        depth: Int,
        bestEffortUnreadableEntries: Bool
    ) throws {
        guard depth <= 64 else {
            if bestEffortUnreadableEntries { return }
            throw CocoaError(.fileReadTooLarge)
        }

        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: path, isDirectory: true)
        let entries: [FileItem]
        do {
            entries = try listDirectory(at: sourceURL)
        } catch {
            if bestEffortUnreadableEntries { return }
            throw error
        }

        for entry in entries {
            let name = entry.name
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                if bestEffortUnreadableEntries { continue }
                throw CoreMediaReaderError.pathOutsideVirtualRoot
            }

            let remoteChild = sourceURL.appendingPathComponent(name)
            let localChild = destinationURL.appendingPathComponent(name, isDirectory: entry.type == .folder)
            do {
                switch entry.type {
                case .folder:
                    try copyDirectoryToLocal(
                        atPath: remoteChild.path,
                        to: localChild,
                        depth: depth + 1,
                        bestEffortUnreadableEntries: bestEffortUnreadableEntries
                    )
                case .file:
                    let data = try readFileData(atPath: remoteChild.path)
                    try data.write(to: localChild, options: .atomic)
                case .symlink:
                    try FileManager.default.createSymbolicLink(
                        atPath: localChild.path,
                        withDestinationPath: entry.destURL.path
                    )
                }
            } catch {
                if !bestEffortUnreadableEntries { throw error }
            }
        }
    }

    private static func withRetryingSession<T>(
        at path: String,
        attempts: Int = 3,
        operation: (CoreMediaSession) throws -> T
    ) throws -> T {
        let retryCount = max(1, attempts)
        let backoff: [TimeInterval] = [0.15, 0.35]
        var lastError: Error?

        for attempt in 0..<retryCount {
            do {
                return try withSerializedSession(operation)
            } catch {
                lastError = error
                guard attempt + 1 < retryCount, isTransientSessionError(error) else {
                    throw error
                }
                let delay = backoff[min(attempt, backoff.count - 1)]
                print("[libexec] transient CoreMedia failure for \(path); retry \(attempt + 2)/\(retryCount): \(error.localizedDescription)")
                Thread.sleep(forTimeInterval: delay)
            }
        }

        throw lastError ?? CoreMediaReaderError.coreMediaUnavailable
    }

    private static func isTransientSessionError(_ error: Error) -> Bool {
        guard let readerError = error as? CoreMediaReaderError else { return false }
        switch readerError {
        case .connectionInterrupted, .xpcUnavailable, .memoryOriginHandshakeFailed, .coreMediaUnavailable, .couldNotOpenPath, .readFailed:
            // A file that was present in the CoreMedia listing may fail one
            // open while the bytestream endpoint is recovering. Re-open once
            // with a fresh XPC session before reporting the failure.
            return true
        default:
            return false
        }
    }

    private static func validateVirtualPath(_ path: String) throws {
        let isUsrPath = path == remotePath || path.hasPrefix(remotePath + "/")
        guard isUsrPath else {
            throw CoreMediaReaderError.pathOutsideVirtualRoot
        }
        // Reject traversal components rather than relying only on standardizedFileURL.
        let components = path.split(separator: "/")
        guard !components.contains("..") else {
            throw CoreMediaReaderError.pathOutsideVirtualRoot
        }
    }

    private static func withSerializedSession<T>(_ operation: (CoreMediaSession) throws -> T) throws -> T {
        sessionLock.lock()
        var session: CoreMediaSession?
        defer {
            // Tear down the XPC connection before allowing the next session to start.
            session = nil
            sessionLock.unlock()
        }
        session = try CoreMediaSession()
        return try operation(session!)
    }

    private static func listDirectoryUncached(at path: String) throws -> [FileItem] {
        return try withRetryingSession(at: path) { session in
            try session.listDirectory(at: path)
        }
    }

    private static func makeFolderItem(at url: URL) -> FileItem {
        let epochDate = Date(timeIntervalSince1970: 0)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd-yyyy h:mm a"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let epochDateString = formatter.string(from: epochDate)

        return FileItem(
            name: url.lastPathComponent,
            fileURL: url,
            destURL: url,
            type: .folder,
            uttype: .folder,
            size: 0,
            creationDate: epochDate,
            modifiedDate: epochDate,
            creationDateStr: epochDateString,
            modifiedDateStr: epochDateString,
            hidden: false,
            posixPerms: "",
            owner: "",
            group: "",
            readable: nil,
            writable: nil,
            executable: nil
        )
    }

    private enum CoreMediaReaderError: LocalizedError {
        case pathOutsideVirtualRoot
        case coreMediaUnavailable
        case xpcUnavailable
        case memoryOriginHandshakeFailed
        case connectionInterrupted(String)
        case couldNotOpenPath(String)
        case notDirectory(String)
        case notRegularFile(String)
        case fileTooLarge(Int64, Int)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .pathOutsideVirtualRoot:
                return "The virtual reader is limited to /usr/libexec."
            case .coreMediaUnavailable:
                return "CoreMedia could not be loaded or a required symbol is unavailable."
            case .xpcUnavailable:
                return "The CoreMedia bytestream XPC service is unavailable."
            case .memoryOriginHandshakeFailed:
                return "The CoreMedia memory-origin handshake could not be established."
            case .connectionInterrupted(let path):
                return "The CoreMedia XPC connection was interrupted while opening \(path)."
            case .couldNotOpenPath(let path):
                return "CoreMedia could not open \(path)."
            case .notDirectory(let path):
                return "\(path) is not a directory."
            case .notRegularFile(let path):
                return "\(path) is not a regular file."
            case .fileTooLarge(let size, let limit):
                return "File is \(size) bytes; the in-memory preview limit is \(limit) bytes."
            case .readFailed(let path):
                return "Could not read \(path)."
            }
        }
    }

    private final class CoreMediaSession {
        private typealias FBasic = @convention(c) (UInt32, UInt64, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
        private typealias FBegin = @convention(c) (UnsafeMutableRawPointer?) -> Int32
        private typealias FComplete = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
        private typealias FRecipient = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32
        private typealias FSetURL = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UnsafeRawPointer?) -> Int32
        private typealias FConnectionCreate = @convention(c) (UnsafePointer<CChar>, UnsafeMutableRawPointer?, UInt64) -> UnsafeMutableRawPointer?
        private typealias FSetEventHandler = @convention(c) (UnsafeMutableRawPointer?, AnyObject) -> Void
        private typealias FResume = @convention(c) (UnsafeMutableRawPointer?) -> Void
        private typealias FCancel = @convention(c) (UnsafeMutableRawPointer?) -> Void
        private typealias FSendReply = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, AnyObject) -> Void
        private typealias FGetValue = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> OpaquePointer?
        private typealias FGetUInt64 = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> UInt64
        private typealias FSetUInt64 = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UInt64) -> Void
        private typealias FDupFD = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Int32
        private typealias FGetType = @convention(c) (OpaquePointer?) -> OpaquePointer?
        private typealias FTypeName = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        private typealias FRetain = @convention(c) (OpaquePointer?) -> Void
        private typealias FRelease = @convention(c) (OpaquePointer?) -> Void

        private let coreMediaHandle: UnsafeMutableRawPointer
        private let connection: UnsafeMutableRawPointer
        private let fBasic: FBasic
        private let fBegin: FBegin
        private let fComplete: FComplete
        private let fRecipient: FRecipient
        private let fSetURL: FSetURL
        private let fSetEventHandler: FSetEventHandler
        private let fResume: FResume
        private let fCancel: FCancel
        private let fSendReply: FSendReply
        private let fGetValue: FGetValue
        private let fGetUInt64: FGetUInt64
        private let fSetUInt64: FSetUInt64
        private let fDupFD: FDupFD
        private let fGetType: FGetType
        private let fTypeName: FTypeName
        private let fRetain: FRetain
        private let fRelease: FRelease

        private var memoryRecipient: UnsafeMutableRawPointer?
        private var memoryOrigin: UnsafeMutableRawPointer?

        /// Synchronizes XPC reply ownership across the timeout and reply-handler
        /// paths. A reply arriving after timeout must be released, not retained
        /// in a captured local that the caller will never read again.
        private final class ReplyState {
            let lock = NSLock()
            var timedOut = false
            var completed = false
            var reply: OpaquePointer?
            var replyType = "?"
        }

        init() throws {
            guard let coreMedia = dlopen(
                "/System/Library/Frameworks/CoreMedia.framework/CoreMedia",
                RTLD_NOW | RTLD_LOCAL
            ) else {
                throw CoreMediaReaderError.coreMediaUnavailable
            }

            let rtld = UnsafeMutableRawPointer(bitPattern: -2)
            guard
                let pBasic = dlsym(coreMedia, "FigXPCCreateBasicMessage"),
                let pBegin = dlsym(coreMedia, "FigMemoryOriginBeginEstablishingMemoryRecipientByFillingInXPCMessage1"),
                let pComplete = dlsym(coreMedia, "FigMemoryOriginCompleteEstablishingMemoryRecipientUsingXPCMessage2"),
                let pRecipient = dlsym(coreMedia, "FigMemoryRecipientCreateWithXPCMessage1AndUpdateXPCMessage2"),
                let pSetURL = dlsym(coreMedia, "FigXPCMessageSetCFURL"),
                let pConnectionCreate = dlsym(rtld, "xpc_connection_create_mach_service"),
                let pSetEventHandler = dlsym(rtld, "xpc_connection_set_event_handler"),
                let pResume = dlsym(rtld, "xpc_connection_resume"),
                let pCancel = dlsym(rtld, "xpc_connection_cancel"),
                let pSendReply = dlsym(rtld, "xpc_connection_send_message_with_reply"),
                let pGetValue = dlsym(rtld, "xpc_dictionary_get_value"),
                let pGetUInt64 = dlsym(rtld, "xpc_dictionary_get_uint64"),
                let pSetUInt64 = dlsym(rtld, "xpc_dictionary_set_uint64"),
                let pDupFD = dlsym(rtld, "xpc_dictionary_dup_fd"),
                let pGetType = dlsym(rtld, "xpc_get_type"),
                let pTypeName = dlsym(rtld, "xpc_type_get_name"),
                let pRetain = dlsym(rtld, "xpc_retain"),
                let pRelease = dlsym(rtld, "xpc_release")
            else {
                dlclose(coreMedia)
                throw CoreMediaReaderError.coreMediaUnavailable
            }

            guard let newConnection = "com.apple.coremedia.mediaplaybackd.bytestream.xpc".withCString({
                unsafeBitCast(pConnectionCreate, to: FConnectionCreate.self)($0, nil, 0)
            }) else {
                dlclose(coreMedia)
                throw CoreMediaReaderError.xpcUnavailable
            }

            self.coreMediaHandle = coreMedia
            self.connection = newConnection
            self.fBasic = unsafeBitCast(pBasic, to: FBasic.self)
            self.fBegin = unsafeBitCast(pBegin, to: FBegin.self)
            self.fComplete = unsafeBitCast(pComplete, to: FComplete.self)
            self.fRecipient = unsafeBitCast(pRecipient, to: FRecipient.self)
            self.fSetURL = unsafeBitCast(pSetURL, to: FSetURL.self)
            self.fSetEventHandler = unsafeBitCast(pSetEventHandler, to: FSetEventHandler.self)
            self.fResume = unsafeBitCast(pResume, to: FResume.self)
            self.fCancel = unsafeBitCast(pCancel, to: FCancel.self)
            self.fSendReply = unsafeBitCast(pSendReply, to: FSendReply.self)
            self.fGetValue = unsafeBitCast(pGetValue, to: FGetValue.self)
            self.fGetUInt64 = unsafeBitCast(pGetUInt64, to: FGetUInt64.self)
            self.fSetUInt64 = unsafeBitCast(pSetUInt64, to: FSetUInt64.self)
            self.fDupFD = unsafeBitCast(pDupFD, to: FDupFD.self)
            self.fGetType = unsafeBitCast(pGetType, to: FGetType.self)
            self.fTypeName = unsafeBitCast(pTypeName, to: FTypeName.self)
            self.fRetain = unsafeBitCast(pRetain, to: FRetain.self)
            self.fRelease = unsafeBitCast(pRelease, to: FRelease.self)

            let eventHandler: @convention(block) (UnsafeMutableRawPointer?) -> Void = { _ in }
            self.fSetEventHandler(self.connection, eventHandler as AnyObject)
            self.fResume(self.connection)

            do {
                try establishMemoryOrigin()
            } catch {
                releaseFigReference(memoryOrigin)
                releaseFigReference(memoryRecipient)
                memoryOrigin = nil
                memoryRecipient = nil
                self.fCancel(self.connection)
                self.fRelease(OpaquePointer(self.connection))
                dlclose(coreMedia)
                throw error
            }
        }

        deinit {
            releaseFigReference(memoryOrigin)
            releaseFigReference(memoryRecipient)
            fCancel(connection)
            fRelease(OpaquePointer(connection))
            dlclose(coreMediaHandle)
        }

        private func releaseFigReference(_ pointer: UnsafeMutableRawPointer?) {
            guard let pointer else { return }
            Unmanaged<CFTypeRef>.fromOpaque(pointer).release()
        }

        private func typeName(_ object: OpaquePointer?) -> String {
            guard let object, let type = fGetType(object), let name = fTypeName(type) else { return "?" }
            return String(cString: name)
        }

        private func send(_ message: UnsafeMutableRawPointer?) -> (OpaquePointer?, String) {
            guard let message else { return (nil, "nil") }
            let semaphore = DispatchSemaphore(value: 0)
            let state = ReplyState()
            let replyHandler: @convention(block) (UnsafeMutableRawPointer?) -> Void = { object in
                var receivedType = "?"
                var retainedReply: OpaquePointer?
                if let object {
                    receivedType = self.typeName(OpaquePointer(object))
                    if receivedType == "dictionary" || receivedType == "error" {
                        self.fRetain(OpaquePointer(object))
                        retainedReply = OpaquePointer(object)
                    }
                }

                state.lock.lock()
                if state.timedOut {
                    state.lock.unlock()
                    if let retainedReply { self.fRelease(retainedReply) }
                } else {
                    state.reply = retainedReply
                    state.replyType = receivedType
                    state.completed = true
                    state.lock.unlock()
                }
                semaphore.signal()
            }

            fSendReply(connection, message, nil, replyHandler as AnyObject)
            let waitResult = semaphore.wait(timeout: .now() + 8)

            state.lock.lock()
            if waitResult == .success || state.completed {
                let result = (state.reply, state.replyType)
                state.reply = nil // Transfer the retained XPC object to the caller.
                state.lock.unlock()
                return result
            }

            state.timedOut = true
            state.lock.unlock()
            // This session cannot be used for another message after a timeout.
            // Cancel it now so a delayed reply cannot keep the connection alive.
            fCancel(connection)
            return (nil, "timeout-8s")
        }

        private func establishMemoryOrigin() throws {
            var rp2Ready = false
            var handshakeReady = false

            var rp1Message: UnsafeMutableRawPointer?
            if fBasic(0x2e727031, 0, &rp1Message) == 0, let message1 = rp1Message {
                let (reply1, replyType1) = send(message1)
                fRelease(OpaquePointer(message1))
                if let reply1, replyType1 == "dictionary" {
                    var rp2Message: UnsafeMutableRawPointer?
                    if fBasic(0x2e727032, 0, &rp2Message) == 0, let message2 = rp2Message {
                        let recipientStatus = "mconf".withCString {
                            fRecipient(reply1, message2, $0, &memoryRecipient)
                        }
                        if recipientStatus == 0, memoryRecipient != nil {
                            let (reply2, replyType2) = send(message2)
                            rp2Ready = replyType2 == "dictionary" && reply2 != nil
                            if let reply2 { fRelease(reply2) }
                        }
                        fRelease(OpaquePointer(message2))
                    }
                    fRelease(reply1)
                }
            }

            if rp2Ready {
                var originMessage: UnsafeMutableRawPointer?
                if fBasic(0x2e6f7267, 0, &originMessage) == 0, let message = originMessage {
                    if fBegin(message) == 0 {
                        let (originReply, originReplyType) = send(message)
                        if let originReply {
                            if originReplyType == "dictionary" {
                                let status = fComplete(originReply, &memoryOrigin)
                                handshakeReady = status == 0 && memoryOrigin != nil
                            }
                            fRelease(originReply)
                        }
                    }
                    fRelease(OpaquePointer(message))
                }
            }

            guard handshakeReady else {
                throw CoreMediaReaderError.memoryOriginHandshakeFailed
            }
        }

        private func openDescriptor(for path: String, isDirectory: Bool = false) throws -> Int32 {
            // FigXPCMessageSetCFURL receives URL metadata, including the directory
            // bit. Mark directory roots and traversed folders explicitly; passing
            // them as ordinary file URLs can make CoreMedia's open result unstable
            // for some /Library trees (notably Ringtones).
            let fileURL = URL(fileURLWithPath: path, isDirectory: isDirectory) as CFURL
            var message: UnsafeMutableRawPointer?
            guard fBasic(0x4375726c, 0, &message) == 0, let message else {
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }
            _ = fSetURL(message, "CreationURL", Unmanaged.passUnretained(fileURL).toOpaque())
            fSetUInt64(message, "FileOpenOptions", 0)
            let (reply, replyType) = send(message)
            fRelease(OpaquePointer(message))

            guard replyType == "dictionary", let reply else {
                if let reply { fRelease(reply) }
                if replyType == "timeout-8s" || (reply == nil && replyType == "?") {
                    throw CoreMediaReaderError.connectionInterrupted(path)
                }
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }
            guard let details = "ByteStreamDetails".withCString({ fGetValue(reply, $0) }) else {
                fRelease(reply)
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }

            let objectID = "ObjectID".withCString { fGetUInt64(details, $0) }
            let fileDescriptor = "FileDescriptor".withCString { fDupFD(details, $0) }

            var closeMessage: UnsafeMutableRawPointer?
            if fBasic(0x646f6f6d, objectID, &closeMessage) == 0, let closeMessage {
                let (closeReply, _) = send(closeMessage)
                if let closeReply { fRelease(closeReply) }
                fRelease(OpaquePointer(closeMessage))
            }
            fRelease(reply)

            guard fileDescriptor >= 0 else {
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }
            return fileDescriptor
        }

        func fileItem(at path: String) throws -> FileItem {
            let fd = try openDescriptor(for: path, isDirectory: true)
            defer { close(fd) }

            var metadata = stat()
            guard fstat(fd, &metadata) == 0 else {
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }

            let kind = metadata.st_mode & mode_t(Darwin.S_IFMT)
            let isDirectory = kind == mode_t(Darwin.S_IFDIR)
            guard isDirectory || kind == mode_t(Darwin.S_IFREG) else {
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }

            let url = URL(fileURLWithPath: path, isDirectory: isDirectory)
            return makeFileItem(name: url.lastPathComponent, url: url, metadata: metadata, isDirectory: isDirectory)
        }

        func itemKind(at path: String, directoryHint: Bool = false) throws -> RemoteItemKind {
            let fd = try openDescriptor(for: path, isDirectory: directoryHint)
            defer { close(fd) }
            var itemStat = stat()
            guard fstat(fd, &itemStat) == 0 else {
                throw CoreMediaReaderError.couldNotOpenPath(path)
            }
            let kind = itemStat.st_mode & mode_t(Darwin.S_IFMT)
            if kind == mode_t(Darwin.S_IFDIR) { return .directory }
            if kind == mode_t(Darwin.S_IFREG) { return .regularFile }
            return .other
        }

        func listDirectory(at path: String) throws -> [FileItem] {
            let directoryFD = try openDescriptor(for: path, isDirectory: true)
            guard let directory = fdopendir(directoryFD) else {
                close(directoryFD)
                throw CoreMediaReaderError.notDirectory(path)
            }
            defer { closedir(directory) }
            let enumerationFD = dirfd(directory)
            var items: [FileItem] = []

            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw CoreMediaReaderError.readFailed(path) }
                    break
                }
                let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }

                // fstatat() can return incomplete or synthetic metadata for a
                // CoreMedia directory FD. Use it only to reject known symlinks and
                // special files; obtain the authoritative timestamps and POSIX mode
                // from the descriptor opened for the child itself. The virtual
                // /usr/libexec Info view presents its system ownership as root:wheel.
                var directoryEntryStat = stat()
                let statResult = name.withCString {
                    fstatat(enumerationFD, $0, &directoryEntryStat, AT_SYMLINK_NOFOLLOW)
                }

                let childURL = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
                let childPath = childURL.standardizedFileURL.path
                let expectedDirectory: Bool

                if statResult == 0 {
                    let entryMode = directoryEntryStat.st_mode & mode_t(Darwin.S_IFMT)
                    guard entryMode == mode_t(Darwin.S_IFDIR) || entryMode == mode_t(Darwin.S_IFREG) else {
                        continue
                    }
                    expectedDirectory = entryMode == mode_t(Darwin.S_IFDIR)
                } else {
                    // Preserve the PoC fallback when fstatat() on a CoreMedia
                    // directory FD cannot stat a child name.
                    let entryType = entry.pointee.d_type
                    if entryType == UInt8(DT_DIR) || entryType == 4 {
                        expectedDirectory = true
                    } else if entryType == UInt8(DT_REG) {
                        expectedDirectory = false
                    } else if entryType == UInt8(DT_UNKNOWN) {
                        // An unknown entry type is not proof that this is a
                        // symlink. Restart the listing with a fresh CoreMedia
                        // session instead of silently omitting a real file.
                        throw CoreMediaReaderError.readFailed(childPath)
                    } else {
                        // Known symlink and special entries are not followed.
                        continue
                    }
                }

                let childFD: Int32
                do {
                    childFD = try openDescriptor(for: childPath, isDirectory: expectedDirectory)
                } catch {
                    if CoreMediaUsrLibexecReader.isTransientSessionError(error) {
                        throw error
                    }
                    continue
                }
                defer { close(childFD) }

                var itemStat = stat()
                guard fstat(childFD, &itemStat) == 0 else {
                    throw CoreMediaReaderError.readFailed(childPath)
                }
                let childType = itemStat.st_mode & mode_t(Darwin.S_IFMT)
                let childIsDirectory = childType == mode_t(Darwin.S_IFDIR)
                let childIsRegularFile = childType == mode_t(Darwin.S_IFREG)
                guard (expectedDirectory && childIsDirectory) || (!expectedDirectory && childIsRegularFile) else {
                    continue
                }

                items.append(makeFileItem(name: name, url: childURL, metadata: itemStat, isDirectory: childIsDirectory))
            }
            return items
        }

        func directoryContentSize(at path: String) throws -> Int64 {
            var visitedEntries = 0
            return try directoryContentSize(at: path, depth: 0, visitedEntries: &visitedEntries)
        }

        private func directoryContentSize(at path: String, depth: Int, visitedEntries: inout Int) throws -> Int64 {
            guard depth <= 64 else { throw CoreMediaReaderError.readFailed(path) }
            let directoryFD = try openDescriptor(for: path, isDirectory: true)
            var rootStat = stat()
            guard fstat(directoryFD, &rootStat) == 0,
                  (rootStat.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFDIR),
                  let directory = fdopendir(directoryFD) else {
                close(directoryFD)
                throw CoreMediaReaderError.notDirectory(path)
            }
            defer { closedir(directory) }

            let enumerationFD = dirfd(directory)
            var total: Int64 = 0
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw CoreMediaReaderError.readFailed(path) }
                    break
                }
                let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
                let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }

                visitedEntries += 1
                guard visitedEntries <= 200_000 else { throw CoreMediaReaderError.readFailed(path) }

                // As in listDirectory(), fstatat() is only a hint for the entry
                // type. The child descriptor's fstat() remains authoritative.
                var directoryEntryStat = stat()
                let statResult = name.withCString {
                    fstatat(enumerationFD, $0, &directoryEntryStat, AT_SYMLINK_NOFOLLOW)
                }
                let expectedDirectory: Bool
                if statResult == 0 {
                    let entryKind = directoryEntryStat.st_mode & mode_t(Darwin.S_IFMT)
                    if entryKind == mode_t(Darwin.S_IFDIR) {
                        expectedDirectory = true
                    } else if entryKind == mode_t(Darwin.S_IFREG) {
                        expectedDirectory = false
                    } else {
                        // Do not follow symlinks or count special filesystem nodes.
                        continue
                    }
                } else {
                    // CoreMedia directory descriptors may not support fstatat().
                    // Fall back only when readdir supplies a known ordinary type.
                    let entryType = entry.pointee.d_type
                    if entryType == UInt8(DT_DIR) || entryType == 4 {
                        expectedDirectory = true
                    } else if entryType == UInt8(DT_REG) {
                        expectedDirectory = false
                    } else if entryType == 0 {
                        // Unknown d_type means we cannot prove the traversal is complete.
                        throw CoreMediaReaderError.readFailed(path + "/" + name)
                    } else {
                        // Known symlink/special entries are intentionally excluded.
                        continue
                    }
                }

                let childPath = URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent(name).standardizedFileURL.path
                do {
                    let childFD: Int32
                    do {
                        childFD = try openDescriptor(for: childPath, isDirectory: expectedDirectory)
                    } catch {
                        // A partial total would be misleading: fail the whole size.
                        throw CoreMediaReaderError.readFailed(childPath)
                    }
                    // Scope this defer to one entry. A defer in the while-loop
                    // body would otherwise retain every descriptor until the
                    // entire directory traversal returned.
                    defer { close(childFD) }

                    var childStat = stat()
                    guard fstat(childFD, &childStat) == 0 else {
                        throw CoreMediaReaderError.readFailed(childPath)
                    }
                    let childKind = childStat.st_mode & mode_t(Darwin.S_IFMT)
                    if expectedDirectory && childKind == mode_t(Darwin.S_IFDIR) {
                        let childSize = try directoryContentSize(at: childPath, depth: depth + 1, visitedEntries: &visitedEntries)
                        let (sum, overflow) = total.addingReportingOverflow(childSize)
                        guard !overflow else { throw CoreMediaReaderError.readFailed(childPath) }
                        total = sum
                    } else if !expectedDirectory && childKind == mode_t(Darwin.S_IFREG) {
                        guard childStat.st_size >= 0 else {
                            throw CoreMediaReaderError.readFailed(childPath)
                        }
                        // Verify that the returned bytestream descriptor is actually
                        // readable, not merely stat-able. Empty files need no probe.
                        if childStat.st_size > 0 {
                            var probe: UInt8 = 0
                            var probeResult: Int
                            repeat {
                                probeResult = pread(childFD, &probe, 1, 0)
                            } while probeResult < 0 && errno == EINTR
                            guard probeResult == 1 else {
                                throw CoreMediaReaderError.readFailed(childPath)
                            }
                        }
                        let (sum, overflow) = total.addingReportingOverflow(Int64(childStat.st_size))
                        guard !overflow else { throw CoreMediaReaderError.readFailed(childPath) }
                        total = sum
                    } else {
                        throw CoreMediaReaderError.readFailed(childPath)
                    }
                }
            }
            return total
        }

        func readFileData(at path: String, maximumBytes: Int) throws -> Data {
            let fd = try openDescriptor(for: path)
            defer { close(fd) }

            var fileStat = stat()
            guard fstat(fd, &fileStat) == 0 else {
                throw CoreMediaReaderError.readFailed(path)
            }
            guard (fileStat.st_mode & mode_t(Darwin.S_IFMT)) == mode_t(Darwin.S_IFREG) else {
                throw CoreMediaReaderError.notRegularFile(path)
            }

            let size = Int64(fileStat.st_size)
            guard size >= 0, size <= Int64(maximumBytes) else {
                throw CoreMediaReaderError.fileTooLarge(size, maximumBytes)
            }

            var result = Data()
            result.reserveCapacity(Int(size))
            var offset: off_t = 0
            let chunkSize = 64 * 1024
            while offset < off_t(size) {
                let remaining = Int(off_t(size) - offset)
                var buffer = [UInt8](repeating: 0, count: min(chunkSize, remaining))
                let count = pread(fd, &buffer, buffer.count, offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw CoreMediaReaderError.readFailed(path)
                }
                if count == 0 { break }
                result.append(contentsOf: buffer.prefix(count))
                offset += off_t(count)
            }
            guard result.count == Int(size) else {
                throw CoreMediaReaderError.readFailed(path)
            }
            return result
        }

        private func makeFileItem(name: String, url: URL, metadata: stat, isDirectory: Bool) -> FileItem {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd-yyyy h:mm a"
            formatter.locale = Locale(identifier: "en_US_POSIX")

            // CoreMedia's bytestream stat timestamps are not reliable for this
            // virtual listing. Match the epoch placeholder used for other system
            // paths when the filesystem does not expose trustworthy dates.
            let creationDate = Date(timeIntervalSince1970: 0)
            let modifiedDate = creationDate
            let mode = metadata.st_mode & 0o7777
            let extensionType = UTType(filenameExtension: url.pathExtension) ?? .data

            return FileItem(
                name: name,
                fileURL: url,
                destURL: url,
                type: isDirectory ? .folder : .file,
                uttype: isDirectory ? .folder : extensionType,
                size: max(0, Int(metadata.st_size)),
                creationDate: creationDate,
                modifiedDate: modifiedDate,
                creationDateStr: formatter.string(from: creationDate),
                modifiedDateStr: formatter.string(from: modifiedDate),
                hidden: name.hasPrefix("."),
                posixPerms: String(format: "%04o", UInt32(mode)),
                owner: POSIXIdentityResolver.userName(metadata.st_uid),
                group: POSIXIdentityResolver.groupName(metadata.st_gid),
                readable: (mode & 0o444) != 0,
                // Keep POSIX mode above as returned by CoreMedia, but the separate
                // Writable field describes effective Erosion access. /usr/libexec
                // is in the app's explicit read-only system-path allowlist.
                writable: !SystemReadOnlyAccess.isReadOnly(url) && (mode & 0o222) != 0,
                executable: (mode & 0o111) != 0
            )
        }
    }

    private enum RemoteItemKind {
        case directory
        case regularFile
        case other
    }
}

extension Notification.Name {
    static let erosionUsrLibexecDirectoryReady = Notification.Name("ErosionUsrLibexecDirectoryReady")
}
