import Foundation
import UIKit
import Combine
import ZIPFoundation

private func airliftFileLogCallback(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let msg else { return }
    AirliftBridge.shared.appendLog(String(cString: msg))
}

private func airliftPasscodeLogCallback(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?) {
    guard let msg else { return }
    let line = String(cString: msg)
    DispatchQueue.main.async {
        AirliftBridge.shared.appendPasscodeLog("  \(line)")
    }
}

struct AirliftAppContainer: Identifiable, Equatable {
    let bundleID: String
    let container: String
    var id: String { bundleID }
}

final class AirliftBridge: ObservableObject, @unchecked Sendable {
    static let shared = AirliftBridge()
    enum State: Equatable { case idle, pairing, ready(pairingPath: String), running, done(ok: Bool, message: String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var pairPIN: String? = nil
    @Published private(set) var pairingStatus: String = ""
    @Published private(set) var exploitLog: [String] = []
    @Published private(set) var installedAppContainers: [AirliftAppContainer] = []
    @Published private(set) var appScanLog: [String] = []
    @Published private(set) var appScanRunning = false
    @Published private(set) var themingReady = UserDefaults.standard.bool(forKey: "airliftThemingReady")
    @Published var target: String = "/var/mobile/Library/SpringBoard"
    @Published var readTarget: String = "/var/mobile/Library/Preferences/com.apple.springboard.plist"
    @Published private(set) var readRunning = false
    @Published private(set) var readResult: String = ""
    @Published private(set) var readExportPath: String? = nil
    @Published var showReadView = false
    @Published private(set) var readViewLocalPath: String? = nil
    @Published private(set) var readViewRemotePath: String? = nil
    @Published private(set) var readViewIsFolder = false
    @Published var readKind: ReadKind = .file

    enum ReadKind: String, CaseIterable, Identifiable {
        case file = "File"
        case folder = "Folder"
        var id: String { rawValue }
    }

    // Passcode theme state. This reuses the existing Airlift write primitive;
    // no exploit implementation is duplicated here.
    @Published private(set) var passcodeTheme: ErosionPasscodeTheme? = nil
    @Published private(set) var passcodeFlashRunning = false
    @Published private(set) var passcodeFlashLog: [String] = []
    @Published var passcodeTelephonyVersion: String = "all"
    @Published var passcodeLanguage: String = "all"
    @Published var passcodeBold: String = "both"
    private var loggedLines: [String] = []
    private var appScanHasRunForPairing = false

    // Remote File Browser mutations are serialized so AirTraffic/Books state
    // cannot be changed by two concurrent write/delete transactions.
    private let fileMutationQueue = DispatchQueue(
        label: "com.erosion.airlift.file-mutations",
        qos: .userInitiated
    )

    // Airlift can emit hundreds/thousands of callback lines while a write is
    // running. Coalesce those callbacks before publishing to SwiftUI so the
    // main thread does not re-render once per line.
    private let logBufferLock = NSLock()
    private var pendingLogLines: [String] = []
    private var logFlushScheduled = false

    private init() {
        al_log_init({ _, msg in
            guard let msg = msg else { return }
            let line = String(cString: msg)
            // appendLog is thread-safe and performs its own throttled main-thread
            // publish. Do not dispatch every callback onto the main queue.
            AirliftBridge.shared.appendLog(line)
        }, nil)
    }

    nonisolated func appendLog(_ s: String) {
        logBufferLock.lock()
        pendingLogLines.append(s)
        if pendingLogLines.count > 700 {
            pendingLogLines.removeFirst(pendingLogLines.count - 650)
        }
        let shouldSchedule = !logFlushScheduled
        if shouldSchedule { logFlushScheduled = true }
        logBufferLock.unlock()

        guard shouldSchedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.flushLogBuffer()
        }
    }

    @MainActor
    private func flushLogBuffer() {
        logBufferLock.lock()
        let batch = pendingLogLines
        pendingLogLines.removeAll(keepingCapacity: true)
        logFlushScheduled = false
        let needsAnotherFlush = !pendingLogLines.isEmpty
        logBufferLock.unlock()

        guard !batch.isEmpty else { return }
        loggedLines.append(contentsOf: batch)
        if loggedLines.count > 800 {
            loggedLines.removeFirst(loggedLines.count - 600)
        }
        exploitLog = loggedLines

        if needsAnotherFlush {
            logBufferLock.lock()
            if !logFlushScheduled { logFlushScheduled = true }
            logBufferLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.flushLogBuffer()
            }
        }
    }
    func clearLog() {
        logBufferLock.lock()
        pendingLogLines.removeAll()
        logFlushScheduled = false
        logBufferLock.unlock()
        loggedLines.removeAll()
        exploitLog = []
    }
    func pairingFilePath() -> String { PairingController.pairingFilePath() }
    /// Single gate used by every Airlift-only UI feature.
    /// A feature is ready only when both LocalDevVPN and a valid pairing file are present.
    func airliftFeatureReady() -> Bool {
        NetworkStatus.loopbackVPNUp() && hasPairing()
    }

    func hasPairing() -> Bool {
        let p = pairingFilePath()
        guard FileManager.default.fileExists(atPath: p) else { return false }
        let size = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int) ?? 0
        return size > 0
    }

    func importPairingFileError(_ error: Error) {
        appendLog("[pairing] ❌ Import cancelled/failed: \(error.localizedDescription)")
        pairingStatus = "Import failed"
    }

    func importPairingFile(from url: URL) {
        do {
            let path = try PairingController.importPairingFile(from: url)
            state = .ready(pairingPath: path)
            pairingStatus = "Imported and validated"
            pairPIN = nil
            appScanHasRunForPairing = false
            let localDevReady = NetworkStatus.loopbackVPNUp()
            if isAirliftCompatibilityMode() && localDevReady {
                UserDefaults.standard.set(true, forKey: "airliftThemingReady")
                themingReady = true
            }
            appendLog("[pairing] imported and validated: \(url.lastPathComponent)")
            if isAirliftCompatibilityMode() && !localDevReady {
                appendLog("[pairing] LocalDevVPN is not active; Airlift-only theming remains locked")
            }
        } catch {
            appendLog("[pairing] ❌ \(error.localizedDescription)")
            pairingStatus = "Invalid pairing file"
        }
    }

    func runPairing() {
        guard !hasPairing() else { state = .ready(pairingPath: pairingFilePath()); return }
        state = .pairing; pairingStatus = "Starting host..."; pairPIN = nil
        let ctrl = PairingController.shared
        Task {
            do {
                let path = try await ctrl.startAndWait()
                self.state = .ready(pairingPath: path)
                self.pairingStatus = "Paired"; self.pairPIN = nil
            } catch is CancellationError {
                self.state = .idle; self.pairingStatus = "Cancelled"
            } catch {
                self.state = .idle
                self.pairingStatus = "Failed: \(error.localizedDescription)"
            }
        }
        Task {
            while case .pairing = self.state {
                try? await Task.sleep(nanoseconds: 200_000_000)
                self.pairingStatus = ctrl.pairingStatus
                self.pairPIN = ctrl.pairingPIN
            }
        }
    }
    func cancelPairing() {
        PairingController.shared.softCancel()
        state = .idle; pairingStatus = ""; pairPIN = nil
    }
    func deletePairing() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let canonicalURL = docs.appendingPathComponent("erosion_pairing.plist")
        if fm.fileExists(atPath: canonicalURL.path) { try? fm.removeItem(at: canonicalURL) }
        if let custom = PairingController.customPairingFilePath, fm.fileExists(atPath: custom) {
            try? fm.removeItem(atPath: custom)
        }
        PairingController.customPairingFilePath = nil
        if let files = try? fm.contentsOfDirectory(atPath: docs.path) {
            for f in files {
                guard f.hasSuffix(".plist") || f.hasSuffix(".mobilepairing") || f.hasSuffix(".mobilepair") else { continue }
                try? fm.removeItem(at: docs.appendingPathComponent(f))
            }
        }
        UserDefaults.standard.removeObject(forKey: "erosionPairingHostAltIRK")
        UserDefaults.standard.removeObject(forKey: "airliftThemingReady")
        themingReady = false
        appScanHasRunForPairing = false
        installedAppContainers = []
        appScanLog = []
        state = .idle; pairingStatus = ""; pairPIN = nil
    }
    func runExploit() {
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            state = .done(ok: false, message: "No pairing file"); return
        }
        state = .running; loggedLines.removeAll(); exploitLog = []
        appendLog("[exploit] path=\(pairingPath) target=\(target)")
        let targetDir = target
        Task.detached {
            var outJson: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc: Int32 = pairingPath.withCString { pc in
                targetDir.withCString { tc in
                    al_exploit_run(pc, tc, nil, nil, &outJson, &outError)
                }
            }
            let jsonStr = outJson.flatMap { p -> String? in let s = String(cString: p); al_string_free(p); return s }
            let errStr = outError.flatMap { p -> String? in let s = String(cString: p); al_string_free(p); return s }
            await MainActor.run {
                if rc == 0 {
                    let msg = jsonStr ?? "OK"
                    self.appendLog("[exploit] ok: \(msg)")
                    self.state = .done(ok: true, message: msg)
                } else {
                    let msg = errStr ?? "rc=\(rc)"
                    self.appendLog("[exploit] fail: \(msg)")
                    self.state = .done(ok: false, message: msg)
                }
            }
        }
    }
    /// Enumerates installed application Data containers through InstallationProxy only.
    /// This is kept separate from the normal Airlift exploit/read log.
    func maybeAutoScanInstalledAppContainers() {
        guard isAirliftCompatibilityMode(),
              NetworkStatus.loopbackVPNUp(),
              hasPairing(),
              !appScanRunning,
              !appScanHasRunForPairing else { return }
        appScanHasRunForPairing = true
        scanInstalledAppContainers()
    }

    func scanInstalledAppContainers() {
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            appScanLog.append("[scan] no pairing file")
            return
        }
        guard !appScanRunning else { return }

        appScanRunning = true
        appScanLog = ["[scan] starting InstallationProxy app scan…"]

        Task.detached { [weak self] in
            var outJSON: UnsafeMutablePointer<CChar>?
            var outError: UnsafeMutablePointer<CChar>?
            let rc = pairingPath.withCString { pc in
                al_list_app_containers(pc, nil, nil, &outJSON, &outError)
            }

            let jsonString = outJSON.flatMap { ptr -> String? in
                let value = String(cString: ptr)
                al_string_free(ptr)
                return value
            }
            let errorString = outError.flatMap { ptr -> String? in
                let value = String(cString: ptr)
                al_string_free(ptr)
                return value
            }

            guard rc == 0, let jsonString,
                  let data = jsonString.data(using: .utf8),
                  let apps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                await MainActor.run {
                    self?.appScanLog = ["[scan] failed: \(errorString ?? "rc=\(rc)")"]
                    self?.appScanRunning = false
                }
                return
            }

            let parsed = apps.compactMap { app -> AirliftAppContainer? in
                guard let bundleID = app["bundleID"] as? String,
                      let container = app["container"] as? String else { return nil }
                return AirliftAppContainer(bundleID: bundleID, container: container)
            }

            await MainActor.run {
                self?.installedAppContainers = parsed
                self?.appScanLog = [
                    "[scan] InstallationProxy returned \(parsed.count) application container(s)",
                    "[scan] complete — no device files were read or written"
                ]
                self?.appScanRunning = false
            }
        }
    }

    func readRemoteFile() {
        runRemoteRead(kind: .file)
    }

    func readRemoteFolder() {
        runRemoteRead(kind: .folder)
    }

    /// Reads one selected app-data UUID using the Airlift AirTraffic/AFC reader.
    /// The Application root itself is an InstallationProxy metadata index.
    func readAppContainer(_ app: AirliftAppContainer) {
        readTarget = app.container
        readKind = .folder
        runRemoteRead(kind: .folder)
    }

    private func runRemoteRead(kind: ReadKind) {
        let pairingPath = pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            readResult = "No pairing file"
            return
        }
        let remote = readTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remote.isEmpty else {
            readResult = "Enter a remote path"
            return
        }
        if readRunning { return }

        if let old = readExportPath { try? FileManager.default.removeItem(atPath: old) }
        if let old = readViewLocalPath, old != readExportPath { try? FileManager.default.removeItem(atPath: old) }
        readViewLocalPath = nil
        readViewRemotePath = nil
        readExportPath = nil
        readRunning = true
        readResult = kind == .file ? "Reading…" : "Reading folder…"
        appendLog("[read] target=\(remote) kind=\(kind.rawValue.lowercased())")

        Task.detached { [weak self] in
            var outJSON: UnsafeMutablePointer<CChar>? = nil
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc: Int32 = pairingPath.withCString { pc in
                remote.withCString { tc in
                    switch kind {
                    case .file:
                        return al_exploit_read_file(pc, tc, nil, nil, &outJSON, &outError)
                    case .folder:
                        return al_exploit_read_folder(pc, tc, nil, nil, &outJSON, &outError)
                    }
                }
            }
            let jsonString = outJSON.flatMap { p -> String? in
                let s = String(cString: p); al_string_free(p); return s
            }
            let errorString = outError.flatMap { p -> String? in
                let s = String(cString: p); al_string_free(p); return s
            }

            var display = ""
            var exportedPath: String? = nil
            var operationOK = (rc == 0)
            if rc == 0, let jsonString,
               let jsonData = jsonString.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                operationOK = (obj["ok"] as? Bool) ?? true
                if !operationOK {
                    // A failed/partial JSON result must not look like a usable ZIP.
                    // Older code exposed `localPath` even when fileCount was zero
                    // and ok=false, which sent users to an empty archive.
                    let count = obj["fileCount"] as? Int ?? 0
                    let failed = obj["failedCount"] as? Int ?? 0
                    let failures = obj["failures"] as? [String] ?? []
                    let failureText = failures.isEmpty ? "" : "\n\n" + failures.prefix(5).joined(separator: "\n")
                    display = "Read failed — no complete result was published (\(count) file(s) read, \(failed) failed).\n\(jsonString)\(failureText)"
                } else if let localPath = obj["localPath"] as? String {
                    exportedPath = localPath
                    if kind == .file, let data = try? Data(contentsOf: URL(fileURLWithPath: localPath)) {
                        let preview: String
                        if let text = String(data: data, encoding: .utf8) {
                            preview = String(text.prefix(12000))
                        } else {
                            preview = data.prefix(256).map { String(format: "%02x", $0) }.joined(separator: " ")
                        }
                        let method = obj["method"] as? String ?? ""
                        let readMethodNote = method.hasPrefix("airtraffic") ? "Method: Airlift AirTraffic/AFC; original restored before result.\n" : ""
                        display = "Read OK — \(data.count) bytes\n\(readMethodNote)SHA256: \((obj["sha256"] as? String) ?? "?")\n\n\(preview)"
                    } else {
                        let count = obj["fileCount"] as? Int ?? 0
                        let method = obj["method"] as? String ?? ""
                        if method == "airtraffic-application-root" {
                            let appCount = obj["appCount"] as? Int ?? count
                            display = "Application root read via AirTraffic/AFC — \(appCount) direct child(ren)\nUUID names only; app contents were not recursively exported.\n\(localPath)"
                        } else if method == "airtraffic-application-container-direct-afc-export" {
                            display = "Application container read — \(count) file(s)\nDirectory restored before ZIP creation.\n\(localPath)"
                        } else if method == "airtraffic-application-container-exact-restore" {
                            display = "Application container read — \(count) file(s)\nOriginal directory restored before ZIP creation.\n\(localPath)"
                        } else {
                            display = "Folder read OK — \(count) file(s)\n\(localPath)"
                        }
                    }
                } else {
                    operationOK = false
                    display = "Read result did not include a local output path.\n\(jsonString)"
                }
            } else {
                operationOK = false
                display = errorString ?? jsonString ?? "Read failed (rc=\(rc))"
            }

            await MainActor.run {
                self?.readRunning = false
                self?.readResult = display
                self?.readExportPath = exportedPath
                if rc == 0, operationOK, let exportedPath {
                    self?.readViewRemotePath = remote
                    self?.readViewIsFolder = (kind == .folder)
                    if kind == .file { self?.readViewLocalPath = exportedPath }
                }
                self?.appendLog(operationOK ? "[read] success" : "[read] failed: \(display)")
            }
        }
    }


    static func remotePath(remoteRoot: String, localRoot: String, localURL: URL) -> String {
        let rootURL = URL(fileURLWithPath: localRoot, isDirectory: true).standardizedFileURL
        let fileURL = localURL.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard fileURL.path.hasPrefix(rootPath) else {
            return URL(fileURLWithPath: remoteRoot, isDirectory: true).appendingPathComponent(fileURL.lastPathComponent).path
        }
        let relative = String(fileURL.path.dropFirst(rootPath.count))
        return URL(fileURLWithPath: remoteRoot, isDirectory: true).appendingPathComponent(relative).path
    }

    func openReadView() {
        guard let exported = readExportPath else { return }
        if readViewIsFolder {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("erosion_airlift_view_\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try FileManager.default.unzipItem(at: URL(fileURLWithPath: exported), to: destination)
                readViewLocalPath = destination.path
                showReadView = true
            } catch {
                readResult = "Could not open folder snapshot: \(error.localizedDescription)"
                try? FileManager.default.removeItem(at: destination)
            }
        } else {
            readViewLocalPath = exported
            showReadView = true
        }
    }

    /// True only when the Airlift transport has both required pieces for a
    /// remote File Browser mutation: LocalDevVPN and a valid pairing file.
    func fileBrowserWriteReady() -> Bool {
        NetworkStatus.loopbackVPNUp() && hasPairing()
    }

    /// Writes the edited local snapshot directly back to the exact remote file.
    /// This is a remote operation: it never reports success merely because the
    /// local snapshot was changed.
    func writeBack(localURL: URL, remotePath: String) async -> Bool {
        guard fileBrowserWriteReady() else {
            appendLog("[write] blocked: LocalDevVPN + pairing are both required")
            return false
        }
        guard remotePath.hasPrefix("/") else {
            appendLog("[write] blocked: invalid remote path \(remotePath)")
            return false
        }
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            appendLog("[write] local source missing: \(localURL.path)")
            return false
        }

        let pairing = pairingFilePath()
        let sourcePath = localURL.path
        appendLog("[write] exact target=\(remotePath)")

        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var error: UnsafeMutablePointer<CChar>? = nil
                let rc = pairing.withCString { pc in
                    sourcePath.withCString { sc in
                        remotePath.withCString { tc in
                            al_exploit_write_file(
                                pc,
                                sc,
                                tc,
                                airliftFileLogCallback,
                                nil,
                                &error
                            )
                        }
                    }
                }
                let message = error.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }
                continuation.resume(returning: (rc == 0, message))
            }
        }

        if let message = result.1, !message.isEmpty {
            appendLog("[write] \(message)")
        }
        appendLog(result.0 ? "[write] success: \(remotePath)" : "[write] failed: \(remotePath)")
        return result.0
    }

    /// Removes exactly one remote file or directory. The operation is performed
    /// before the local snapshot item is deleted by the File Browser.
    func removeRemotePath(_ remotePath: String) async -> Bool {
        guard fileBrowserWriteReady() else {
            appendLog("[delete] blocked: LocalDevVPN + pairing are both required")
            return false
        }
        guard remotePath.hasPrefix("/") else {
            appendLog("[delete] blocked: invalid remote path \(remotePath)")
            return false
        }

        let pairing = pairingFilePath()
        appendLog("[delete] exact target=\(remotePath)")
        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var error: UnsafeMutablePointer<CChar>? = nil
                let rc = pairing.withCString { pc in
                    remotePath.withCString { tc in
                        al_exploit_remove_path(
                            pc,
                            tc,
                            airliftFileLogCallback,
                            nil,
                            &error
                        )
                    }
                }
                let message = error.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }
                continuation.resume(returning: (rc == 0, message))
            }
        }

        if let message = result.1, !message.isEmpty {
            appendLog("[delete] \(message)")
        }
        appendLog(result.0 ? "[delete] success: \(remotePath)" : "[delete] failed: \(remotePath)")
        return result.0
    }

    /// Injects a local directory as one exact remote directory. This is also
    /// useful for creating an empty folder because the Airlift folder archive
    /// contains an explicit `payload/` directory entry.
    func createRemoteDirectory(localURL: URL, remotePath: String) async -> Bool {
        guard fileBrowserWriteReady() else {
            appendLog("[mkdir] blocked: LocalDevVPN + pairing are both required")
            return false
        }
        let isDirectory = (try? localURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory else {
            appendLog("[mkdir] local folder missing: \(localURL.path)")
            return false
        }
        guard remotePath.hasPrefix("/") else {
            appendLog("[mkdir] blocked: invalid remote path \(remotePath)")
            return false
        }

        let remoteURL = URL(fileURLWithPath: remotePath, isDirectory: true)
        let parent = remoteURL.deletingLastPathComponent().path
        let name = remoteURL.lastPathComponent
        let pairing = pairingFilePath()
        let sourcePath = localURL.path

        appendLog("[mkdir] exact target=\(remotePath)")
        let result: (Bool, String?) = await withCheckedContinuation { continuation in
            fileMutationQueue.async {
                var error: UnsafeMutablePointer<CChar>? = nil
                let rc = pairing.withCString { pc in
                    sourcePath.withCString { sc in
                        parent.withCString { tc in
                            name.withCString { nc in
                                al_exploit_inject_folder(
                                    pc,
                                    sc,
                                    tc,
                                    nc,
                                    airliftFileLogCallback,
                                    nil,
                                    &error
                                )
                            }
                        }
                    }
                }
                let message = error.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }
                continuation.resume(returning: (rc == 0, message))
            }
        }

        if let message = result.1, !message.isEmpty {
            appendLog("[mkdir] \(message)")
        }
        appendLog(result.0 ? "[mkdir] success: \(remotePath)" : "[mkdir] failed: \(remotePath)")
        return result.0
    }

    func loadPasscodeTheme(url: URL) {
        guard let theme = ErosionPasscodeThemeReader.inspect(url: url) else {
            appendPasscodeLog("❌ Failed to read .passthm")
            return
        }
        passcodeTheme = theme
        passcodeFlashLog = [
            "Loaded: \(theme.name)",
            "Key images: \(theme.keys.count)/10",
            "Theme assets: \(theme.fileCount)"
        ]
    }

    func clearPasscodeTheme() {
        passcodeTheme = nil
        passcodeFlashLog.removeAll()
    }

    func flashPasscodeTheme() {
        guard !passcodeFlashRunning, let theme = passcodeTheme else { return }
        guard NetworkStatus.loopbackVPNUp() && hasPairing() else {
            appendPasscodeLog("❌ LocalDevVPN + pairing file are required")
            return
        }
        let pairingPath = pairingFilePath()

        passcodeFlashRunning = true
        passcodeFlashLog.removeAll()
        let version = passcodeTelephonyVersion
        let language = passcodeLanguage
        let bold = passcodeBold
        var payloads: [String: Data] = theme.rawData
        for (digit, image) in theme.keys where payloads[digit] == nil {
            if let data = image.pngData() {
                payloads[digit] = data
            }
        }

        Task.detached { [weak self] in
            guard let self else { return }

            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("erosion_passthm_stage_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

            let langs: [String] = language == "all"
                ? ["en", "other", "ru", "uk", "es", "fr", "de", "it", "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he"]
                : (language == "other" ? ["other"] : [language, "other"])

            let boldSuffixes: [String]
            switch bold {
            case "bold": boldSuffixes = ["-bold"]
            case "regular": boldSuffixes = [""]
            default: boldSuffixes = ["", "-bold"]
            }

            let subtexts: [String: String] = [
                "0": "+", "1": "", "2": "A B C", "3": "D E F",
                "4": "G H I", "5": "J K L", "6": "M N O",
                "7": "P Q R S", "8": "T U V", "9": "W X Y Z"
            ]
            let ru: [String: String] = [
                "2": "А Б В Г", "3": "Д Е Ж З", "4": "И Й К Л",
                "5": "М Н О П", "6": "Р С Т У", "7": "Ф Х Ц Ч",
                "8": "Ш Щ Ъ Ы", "9": "Ь Э Ю Я"
            ]
            let uk: [String: String] = [
                "2": "А Б В Г", "3": "Д Е Ж З", "4": "І Ї Й К",
                "5": "Л М Н О", "6": "П Р С Т", "7": "У Ф Х Ц",
                "8": "Ч Ш Щ Ь", "9": "Ю Я"
            ]

            for (digit, imageData) in payloads {
                let std = subtexts[digit] ?? ""

                for lang in langs {
                    for suffix in boldSuffixes {
                        let blank = "\(lang)-\(digit)---white\(suffix).png"
                        try? imageData.write(to: stage.appendingPathComponent(blank))

                        if !std.isEmpty {
                            try? imageData.write(to: stage.appendingPathComponent(
                                "\(lang)-\(digit)-\(std)--white\(suffix).png"))
                            let noSpace = std.replacingOccurrences(of: " ", with: "")
                            if noSpace != std {
                                try? imageData.write(to: stage.appendingPathComponent(
                                    "\(lang)-\(digit)-\(noSpace)--white\(suffix).png"))
                            }
                        }

                        if (lang == "ru" || language == "all"), let v = ru[digit] {
                            try? imageData.write(to: stage.appendingPathComponent(
                                "\(lang)-\(digit)-\(v)--white\(suffix).png"))
                        }
                        if (lang == "uk" || language == "all"), let v = uk[digit] {
                            try? imageData.write(to: stage.appendingPathComponent(
                                "\(lang)-\(digit)-\(v)--white\(suffix).png"))
                        }
                    }
                }
            }
            try? Data().write(to: stage.appendingPathComponent("_big"))

            let versions: [String] = version == "all"
                ? ["TelephonyUI-10", "TelephonyUI-9", "TelephonyUI-8"]
                : [version]

            var allOK = true
            for target in versions {
                await MainActor.run { self.appendPasscodeLog("Writing \(target)…") }
                let ok = await self.writeDirectory(
                    pairingPath: pairingPath,
                    source: stage.path,
                    target: "/var/mobile/Library/Caches/\(target)"
                )
                if ok {
                    await MainActor.run { self.appendPasscodeLog("✅ Injected \(target)") }
                } else {
                    allOK = false
                    await MainActor.run { self.appendPasscodeLog("❌ Failed \(target)") }
                }
            }

            try? FileManager.default.removeItem(at: stage)
            let finalOK = allOK
            await MainActor.run {
                self.passcodeFlashRunning = false
                self.appendPasscodeLog(finalOK
                    ? "🎉 Passcode theme applied. Lock the device to see it."
                    : "❌ One or more TelephonyUI targets failed.")
            }
        }
    }

    func appendPasscodeLog(_ line: String) {
        passcodeFlashLog.append(line)
    }

    private func writeDirectory(pairingPath: String, source: String, target: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: UnsafeMutablePointer<CChar>?
                let rc = pairingPath.withCString { p in
                    source.withCString { s in
                        target.withCString { t in
                            al_exploit_write_dir(p, s, t, airliftPasscodeLogCallback, nil, &error)
                        }
                    }
                }
                if let error {
                    let message = String(cString: error)
                    al_string_free(error)
                    DispatchQueue.main.async {
                        self.appendPasscodeLog("  \(message)")
                    }
                }
                continuation.resume(returning: rc == 0)
            }
        }
    }

    func cancelExploit() { /* natsuk1-cancel-v1 */
        appendLog("[exploit] cancel requested")
        state = .done(ok: false, message: "cancelled")
    }

}
