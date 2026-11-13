import SwiftUI
import UIKit
import ZIPFoundation
import UniformTypeIdentifiers

struct AppsManagementView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var preparedDirectories: [String: URL] = [:]
    @State private var preparingBundleIDs: Set<String> = []
    @State private var processingBundleIDs: Set<String> = []
    @State private var alertMessage: String?
    @State private var selectedInfoApp: AirliftAppBundlePath?
    @State private var coreServicesApps: [AirliftAppBundlePath] = []
    @State private var initialLoadCompleted = false
    @State private var initialLoadStarted = false
    @AppStorage("listStyle") private var listStyle = 1

    private var sortedApps: [AirliftAppBundlePath] {
        (airlift.installedAppBundlePaths + coreServicesApps).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var body: some View {
        appList
            .onAppear {
                startInitialLoadIfNeeded()
            }
            .onChange(of: airlift.installedAppBundlePaths) { _, _ in
                reloadPreparedApps()
            }
            .alert("App Decrypt", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .sheet(item: $selectedInfoApp) { app in
                InfoViewer(bundleInfoItem(for: app))
            }
    }

    /// Root list for installed application bundles.
    private var appList: some View {
        List {
            if !initialLoadCompleted {
                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            ProgressView()
                                .offset(y: 0.5)
                            Text("Loading Files...")
                                .fontWeight(.medium)
                        }
                        Text("This may take up to 5 seconds. Ensure you have a valid pairing and localdev.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    if sortedApps.isEmpty {
                        ContentUnavailableView(
                            "No apps found",
                            systemImage: "app.dashed",
                            description: Text("No app bundles were found in CoreServices or the installed-app list.")
                        )
                    } else {
                        ForEach(sortedApps) { app in
                            appRow(app)
                        }
                    }
                } header: {
                    HStack {
                        Text("Applications")
                        Spacer()
                        Text("\(sortedApps.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("App Decrypt")
        .navigationBarTitleDisplayMode(.inline)
        .customListStyle(listStyle)
        .adaptiveListMargin()
    }

    @ViewBuilder
    private func appRow(_ app: AirliftAppBundlePath) -> some View {
        HStack(spacing: 12) {
            AppsManagementAppIcon(app: app)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if preparedDirectories[app.preparedStorageKey] != nil {
                    Text("Prepared")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                } else if preparingBundleIDs.contains(app.preparedStorageKey) {
                    Text("Preparing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if preparingBundleIDs.contains(app.preparedStorageKey) || processingBundleIDs.contains(app.preparedStorageKey) {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                selectedInfoApp = app
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .accessibilityLabel("Get Info for \(app.displayName)")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                prepare(app)
            } label: {
                Label("Prepare", systemImage: "arrow.down.doc")
            }
            .disabled(preparingBundleIDs.contains(app.preparedStorageKey) || processingBundleIDs.contains(app.preparedStorageKey))

            Button {
                createIPA(for: app)
            } label: {
                Label("Decrypt", systemImage: "doc.zipper")
            }
            .disabled(preparedDirectories[app.preparedStorageKey] == nil
                || preparingBundleIDs.contains(app.preparedStorageKey)
                || processingBundleIDs.contains(app.preparedStorageKey))

        }
    }

    private func bundleInfoItem(for app: AirliftAppBundlePath) -> FileItem {
        var item = getFileItem(at: URL(fileURLWithPath: app.path, isDirectory: true))
        item.name = app.displayName
        item.type = .folder
        item.uttype = .folder
        return item
    }

    private func reloadPreparedApps() {
        preparedDirectories = PreparedAppsStorage.preparedDirectories()
    }

    private func startInitialLoadIfNeeded() {
        guard !initialLoadStarted else { return }
        initialLoadStarted = true
        reloadPreparedApps()

        let coreServicesTask = Task.detached(priority: .utility) {
            Self.readCoreServicesApps()
        }
        airlift.scanInstalledAppBundlePathsIfNeeded()

        Task { @MainActor in
            let apps = await coreServicesTask.value
            coreServicesApps = apps

            // InstallationProxy may already be running from File Browser. Keep
            // the loading card visible until that metadata scan reaches a result.
            while airlift.appScanRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            initialLoadCompleted = true
        }
    }

    /// Reads only immediate .app directories from the stock-readable CoreServices path.
    /// This scan intentionally does not use Airlift, InstallationProxy or a VPN.
    private static func readCoreServicesApps() -> [AirliftAppBundlePath] {
        let rootURL = URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { appURL in
            guard appURL.pathExtension.lowercased() == "app",
                  (try? appURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            let infoURL = appURL.appendingPathComponent("Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let bundleID = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !bundleID.isEmpty else { return nil }

            let displayName = [info["CFBundleDisplayName"], info["CFBundleName"]]
                .compactMap { $0 as? String }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty })
                ?? appURL.deletingPathExtension().lastPathComponent

            return AirliftAppBundlePath(
                bundleID: bundleID,
                displayName: displayName,
                path: appURL.standardizedFileURL.path,
                source: .coreServices
            )
        }
    }

    private func prepare(_ app: AirliftAppBundlePath) {
        let storageKey = app.preparedStorageKey
        guard !preparingBundleIDs.contains(storageKey),
              !processingBundleIDs.contains(storageKey) else { return }
        preparingBundleIDs.insert(storageKey)

        if app.source == .coreServices {
            airlift.appendFeatureLog("app-decrypt", "Preparing \(app.displayName) (\(app.bundleID)) directly from CoreServices")
            Task {
                do {
                    let preparedURL = try await Task.detached(priority: .utility) {
                        try PreparedAppsStorage.installLocalBundle(for: app)
                    }.value
                    preparedDirectories[storageKey] = preparedURL
                    preparingBundleIDs.remove(storageKey)
                    airlift.appendFeatureLog("app-decrypt", "Prepared \(app.displayName) from CoreServices.")
                } catch {
                    preparingBundleIDs.remove(storageKey)
                    airlift.appendFeatureLog("app-decrypt", "CoreServices prepare failed for \(app.displayName): \(error.localizedDescription)")
                    alertMessage = error.localizedDescription
                }
            }
            return
        }

        airlift.appendFeatureLog("app-decrypt", "Preparing \(app.displayName) (\(app.bundleID)) through Airlift")
        airlift.readRemotePathForFileOperations(path: app.path, kind: .folder, feature: "apps-management") { success, archiveURL, detail in
            guard success, let archiveURL else {
                preparingBundleIDs.remove(storageKey)
                airlift.appendFeatureLog("app-decrypt", "Prepare failed for \(app.displayName): \(detail)")
                alertMessage = detail.isEmpty ? "Airlift could not read this app bundle." : detail
                return
            }

            Task {
                do {
                    let preparedURL = try await Task.detached(priority: .utility) {
                        try PreparedAppsStorage.installSnapshot(archiveURL, for: app)
                    }.value
                    preparedDirectories[storageKey] = preparedURL
                    preparingBundleIDs.remove(storageKey)
                    airlift.appendFeatureLog("app-decrypt", "Prepared \(app.displayName). The app bundle is saved in Erosion storage.")
                } catch {
                    try? FileManager.default.removeItem(at: archiveURL)
                    preparingBundleIDs.remove(storageKey)
                    airlift.appendFeatureLog("app-decrypt", "Prepare failed for \(app.displayName): \(error.localizedDescription)")
                    alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func createIPA(for app: AirliftAppBundlePath) {
        let storageKey = app.preparedStorageKey
        guard let preparedURL = preparedDirectories[storageKey] else { return }
        guard !processingBundleIDs.contains(storageKey) else { return }
        processingBundleIDs.insert(storageKey)
        airlift.appendFeatureLog("app-decrypt", "Building Payload and packaging \(app.displayName).ipa")
        Task {
            do {
                let ipaURL = try await Task.detached(priority: .utility) {
                    try PreparedAppsStorage.makeIPA(from: preparedURL, displayName: app.displayName)
                }.value
                processingBundleIDs.remove(storageKey)
                airlift.appendFeatureLog("app-decrypt", "IPA package ready: \(ipaURL.lastPathComponent). This packages the prepared .app and does not decrypt FairPlay-encrypted executables.")
                presentShareSheet(with: ipaURL)
            } catch {
                processingBundleIDs.remove(storageKey)
                airlift.appendFeatureLog("app-decrypt", "IPA packaging failed for \(app.displayName): \(error.localizedDescription)")
                alertMessage = error.localizedDescription
            }
        }
    }
}

private struct AppsManagementAppIcon: View {
    @EnvironmentObject private var airlift: AirliftBridge
    let app: AirliftAppBundlePath
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(uiColor: .systemGray4))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .task(id: app.id) {
            image = nil
            if app.source == .coreServices {
                let iconPath = app.path + "/AppIcon60x60@2x.png"
                image = UIImage(contentsOfFile: iconPath)
            } else {
                image = await airlift.fetchAppIcon(bundleID: app.bundleID)
            }

            // Use the stock Posters app icon as the shared fallback for every
            // bundle whose own icon could not be loaded.
            if image == nil, app.bundleID != "com.apple.Posters.UnityPosterApp" {
                image = await airlift.fetchAppIcon(bundleID: "com.apple.Posters.UnityPosterApp")
            }
        }
    }
}

private struct PreparedAppManifest: Codable {
    let bundleID: String
    let displayName: String
    let sourcePath: String
    let appDirectoryName: String
    let preparedAt: Date
    let storageKey: String?
}

private enum PreparedAppsStorage {
    private static var rootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("ErosionAppsManagement", isDirectory: true)
    }

    private static var preparedRootURL: URL {
        rootURL.appendingPathComponent("Prepared", isDirectory: true)
    }

    private static var exportRootURL: URL {
        rootURL.appendingPathComponent("Exports", isDirectory: true)
    }

    static func preparedDirectories() -> [String: URL] {
        let fileManager = FileManager.default
        guard let children = try? fileManager.contentsOfDirectory(
            at: preparedRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var results: [String: URL] = [:]
        for directory in children {
            let manifestURL = directory.appendingPathComponent("prepared.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(PreparedAppManifest.self, from: data) else { continue }
            let appURL = directory.appendingPathComponent(manifest.appDirectoryName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            results[manifest.storageKey ?? manifest.bundleID] = appURL
        }
        return results
    }

    static func installSnapshot(_ archiveURL: URL, for app: AirliftAppBundlePath) throws -> URL {
        let appName = URL(fileURLWithPath: app.path).lastPathComponent
        guard isValidBundlePath(app.path), appName.lowercased().hasSuffix(".app") else {
            throw StorageError.invalidBundlePath
        }

        let fileManager = FileManager.default
        let storageKey = app.preparedStorageKey
        let appStorageDirectory = preparedRootURL.appendingPathComponent(safeComponent(storageKey), isDirectory: true)
        if fileManager.fileExists(atPath: appStorageDirectory.path) {
            try fileManager.removeItem(at: appStorageDirectory)
        }
        try fileManager.createDirectory(at: appStorageDirectory, withIntermediateDirectories: true)

        let appURL = appStorageDirectory.appendingPathComponent(appName, isDirectory: true)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)
        do {
            // The Airlift folder ZIP contains the contents of the remote .app
            // directory at its root, so extract directly into the .app folder.
            try fileManager.unzipItem(at: archiveURL, to: appURL)
            let entries = try fileManager.contentsOfDirectory(atPath: appURL.path)
            guard !entries.isEmpty else { throw StorageError.emptyBundle }
            let restoredExecutables = try restoreExecutablePermissions(in: appURL)

            let manifest = PreparedAppManifest(
                bundleID: app.bundleID,
                displayName: app.displayName,
                sourcePath: app.path,
                appDirectoryName: appName,
                preparedAt: Date(),
                storageKey: storageKey
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: appStorageDirectory.appendingPathComponent("prepared.json"), options: .atomic)
            try? fileManager.removeItem(at: archiveURL)
            _ = restoredExecutables
            return appURL
        } catch {
            try? fileManager.removeItem(at: appStorageDirectory)
            throw error
        }
    }

    /// Copies a CoreServices .app using the process's existing filesystem access.
    /// This path deliberately never invokes Airlift or InstallationProxy.
    static func installLocalBundle(for app: AirliftAppBundlePath) throws -> URL {
        let sourceURL = URL(fileURLWithPath: app.path, isDirectory: true).standardizedFileURL
        let rootPath = "/System/Library/CoreServices/"
        guard app.source == .coreServices,
              sourceURL.path.hasPrefix(rootPath),
              sourceURL.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw StorageError.invalidCoreServicesBundlePath
        }

        let fileManager = FileManager.default
        let appName = sourceURL.lastPathComponent
        let storageKey = app.preparedStorageKey
        let appStorageDirectory = preparedRootURL.appendingPathComponent(safeComponent(storageKey), isDirectory: true)
        if fileManager.fileExists(atPath: appStorageDirectory.path) {
            try fileManager.removeItem(at: appStorageDirectory)
        }
        try fileManager.createDirectory(at: appStorageDirectory, withIntermediateDirectories: true)

        let appURL = appStorageDirectory.appendingPathComponent(appName, isDirectory: true)
        do {
            try fileManager.copyItem(at: sourceURL, to: appURL)
            let entries = try fileManager.contentsOfDirectory(atPath: appURL.path)
            guard !entries.isEmpty else { throw StorageError.emptyBundle }

            let manifest = PreparedAppManifest(
                bundleID: app.bundleID,
                displayName: app.displayName,
                sourcePath: app.path,
                appDirectoryName: appName,
                preparedAt: Date(),
                storageKey: storageKey
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: appStorageDirectory.appendingPathComponent("prepared.json"), options: .atomic)
            return appURL
        } catch {
            try? fileManager.removeItem(at: appStorageDirectory)
            throw error
        }
    }

    /// AFC folder snapshots do not consistently expose remote st_mode bits.
    /// Restore the executable bit for each bundle's declared CFBundleExecutable
    /// so the prepared app and the resulting IPA do not inherit ZIP's 0600 file
    /// mode for every regular file.
    @discardableResult
    private static func restoreExecutablePermissions(in appURL: URL) throws -> Int {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var executablePaths = Set<String>()
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "Info.plist" {
            guard let data = try? Data(contentsOf: fileURL),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = plist as? [String: Any],
                  let executable = dictionary["CFBundleExecutable"] as? String,
                  !executable.isEmpty,
                  !executable.contains("/"),
                  executable != ".", executable != ".." else { continue }

            let executableURL = fileURL.deletingLastPathComponent().appendingPathComponent(executable)
            let path = executableURL.standardizedFileURL.path
            guard path == appURL.standardizedFileURL.path
                    || path.hasPrefix(appURL.standardizedFileURL.path + "/") else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            executablePaths.insert(path)
        }

        // Embedded dynamic libraries are loadable Mach-O images as well. They
        // are not guaranteed to have a separate Info.plist in every package.
        if let enumerator = fileManager.enumerator(at: appURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "dylib" {
                executablePaths.insert(fileURL.standardizedFileURL.path)
            }
        }

        for path in executablePaths {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return executablePaths.count
    }

    static func makeIPA(from appURL: URL, displayName: String) throws -> URL {
        guard appURL.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: appURL.path) else {
            throw StorageError.preparedBundleMissing
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: exportRootURL, withIntermediateDirectories: true)
        let workingDirectory = rootURL.appendingPathComponent("Working-\(UUID().uuidString)", isDirectory: true)
        let payloadDirectory = workingDirectory.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: payloadDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workingDirectory) }

        let payloadAppURL = payloadDirectory.appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: appURL, to: payloadAppURL)

        let packageName = safeFileName(displayName)
        let zipURL = workingDirectory.appendingPathComponent("\(packageName).zip")
        try fileManager.zipItem(at: payloadDirectory, to: zipURL, shouldKeepParent: true)

        let ipaURL = exportRootURL.appendingPathComponent("\(packageName)-\(UUID().uuidString.prefix(8)).ipa")
        try fileManager.moveItem(at: zipURL, to: ipaURL)
        return ipaURL
    }

    private static func isValidBundlePath(_ path: String) -> Bool {
        let root = "/var/containers/Bundle/Application/"
        guard path.hasPrefix(root) else { return false }
        let components = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 2
            && UUID(uuidString: String(components[0])) != nil
            && String(components[1]).lowercased().hasSuffix(".app")
    }

    private static func safeComponent(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return cleaned.isEmpty ? UUID().uuidString : cleaned
    }

    private static func safeFileName(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "[/\\\\:\\n\\r]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Application" : cleaned
    }

    private enum StorageError: LocalizedError {
        case invalidBundlePath
        case invalidCoreServicesBundlePath
        case emptyBundle
        case preparedBundleMissing

        var errorDescription: String? {
            switch self {
            case .invalidBundlePath: return "The app path is not a valid Bundle/Application UUID/<name>.app path."
            case .invalidCoreServicesBundlePath: return "The app is not a readable .app bundle inside /System/Library/CoreServices."
            case .emptyBundle: return "The app bundle was empty; it was not marked as prepared."
            case .preparedBundleMissing: return "The prepared .app bundle could not be found in Erosion storage."
            }
        }
    }
}
