//
//  FileBrowserView.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/12/26.
//

import SwiftUI

import QuickLook

enum FileSortMode: String, CaseIterable, Codable, Hashable {
    case system, name, date, type, size
    
    var id: String { label }
    
    var label: String {
        switch self {
        case .system: return "Default"
        case .name: return "Name"
        case .date: return "Date"
        case .type: return "Type"
        case .size: return "Size"
        }
    }
}

/// Keeps the conditional folder/file row out of FileBrowserView's large List
/// builder. Splitting this view prevents Swift's result-builder type checker
/// from having to infer both row implementations inside the parent ForEach.
private struct FileBrowserItemRow: View {
    let file: FileItem
    let shouldGrant: Bool
    let isContainer: Bool
    let readOnly: Bool
    let airliftRemoteRoot: String?
    let airliftLocalRoot: String?
    let localBasePath: String
    let displayName: String?
    let navigationBlocked: Bool

    private var remoteFilePath: String? {
        guard let remoteRoot = airliftRemoteRoot else { return nil }
        let localRoot = airliftLocalRoot ?? localBasePath
        return AirliftBridge.remotePath(
            remoteRoot: remoteRoot,
            localRoot: localRoot,
            localURL: file.fileURL
        )
    }

    @ViewBuilder
    var body: some View {
        if file.type == .folder {
            FolderRow(
                file: file,
                shouldGrant: isContainer || shouldGrant,
                isContainer: isContainer,
                readOnly: readOnly,
                airliftRemoteRoot: airliftRemoteRoot,
                airliftLocalRoot: airliftLocalRoot,
                displayName: displayName,
                navigationBlocked: navigationBlocked
            )
        } else {
            FileRow(
                file: file,
                readOnly: readOnly,
                airliftRemotePath: remoteFilePath,
                airliftRemoteRoot: airliftRemoteRoot,
                airliftLocalRoot: airliftLocalRoot
            )
        }
    }
}

struct FileBrowserView: View {
    @EnvironmentObject var mgr: ErosionManager
    @ObservedObject private var airlift = AirliftBridge.shared
    var path: URL = URL(fileURLWithPath: "/")
    var isContainer = false
    var shouldGrant = false
    var readOnly = false
    /// Used only by DB5+ Airlift compatibility roots: list immediate container
    /// identifiers but prevent opening the individual container directories.
    var blockContainerEntry = false
    var fixedFiles: [URL]? = nil
    var navigationTitleOverride: String? = nil
    var airliftRemoteRoot: String? = nil
    var airliftLocalRoot: String? = nil
    
    @State private var unfilteredFiles: [FileItem] = []
    @State private var searchText = ""
    @AppStorage("maxInode") var maxInode = 7500000
    @AppStorage("chosenSort") var chosenSort: FileSortMode = .system
    @AppStorage("filesAscend") var filesAscend = true
    @AppStorage("listStyle") var listStyle = 1
    @AppStorage("hideDates") var hideDates = false
    @AppStorage("textViewerSize") var textViewerSize = 10
    @AppStorage("useMonospaced") var useMonospaced = true
    
    @State private var showFileImporter = false
    @State private var showFailure = false
    @State private var failMsg = ""
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var loadGeneration = 0
    @State private var pathJumpDestination: URL? = nil
    @State private var jumpFileURL: URL? = nil
    @State private var showJumpFile = false

    /// Airlift folder reads are local snapshot directories created by Erosion.
    /// They must not be subjected to the system-path readability gate used
    /// by the normal file browser; their local copy is editable in Erosion.
    private var isAirliftSnapshot: Bool {
        airliftLocalRoot != nil
    }

    /// Airlift snapshots are local, writable copies. Viewer edits use the
    /// existing Airlift write-back bridge to update the original remote file.
    private var effectiveReadOnly: Bool {
        isAirliftSnapshot ? false : readOnly
    }

    private var hasAirliftWriteContext: Bool {
        airliftRemoteRoot != nil && airliftLocalRoot != nil
    }

    /// Always derive displayed rows from the complete directory snapshot. Keeping
    /// the filtered list out of @State prevents a cleared query from leaving a
    /// stale single-result list after navigating back from a match.
    private var visibleFiles: [FileItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return unfilteredFiles }
        return unfilteredFiles.filter { file in
            let label = isRestrictedContainerRoot ? restrictedContainerDisplayName(for: file) : file.name
            return label.localizedCaseInsensitiveContains(query)
                || file.fileURL.path.localizedCaseInsensitiveContains(query)
        }
    }

    private func remoteMutationAllowed() -> Bool {
        AirliftBridge.shared.fileBrowserWriteReady()
    }

    private func remotePath(for localURL: URL) -> String? {
        guard let remoteRoot = airliftRemoteRoot, let localRoot = airliftLocalRoot else { return nil }
        return AirliftBridge.remotePath(remoteRoot: remoteRoot, localRoot: localRoot, localURL: localURL)
    }

    private static func normalizedContainerPath(_ value: String) -> String {
        var path = value.hasPrefix("/private/var/")
            ? String(value.dropFirst("/private".count))
            : value
        // InstallationProxy may return the /var/containers aliases for roots
        // shown under /var/mobile/Containers in File Browser. Normalize these
        // metadata paths to one visible row per UUID.
        let aliases: [(String, String)] = [
            ("/var/containers/Data/Application/", "/var/mobile/Containers/Data/Application/"),
            ("/var/containers/Data/PluginKitPlugin/", "/var/mobile/Containers/Data/PluginKitPlugin/"),
            ("/var/containers/Data/InternalDaemon/", "/var/mobile/Containers/Data/InternalDaemon/"),
            ("/var/containers/Shared/AppGroup/", "/var/mobile/Containers/Shared/AppGroup/")
        ]
        for (alias, visibleRoot) in aliases where path.hasPrefix(alias) {
            path = visibleRoot + path.dropFirst(alias.count)
            break
        }
        return path
    }

    private var restrictedContainerRootKind: String? {
        guard airliftUIAccessRequired(), blockContainerEntry, isContainer else { return nil }
        switch Self.normalizedContainerPath(path.standardizedFileURL.path) {
        case Self.normalizedContainerPath(FSURL.appContainers.path): return "data"
        case Self.normalizedContainerPath(FSURL.appGroup.path): return "appGroups"
        case Self.normalizedContainerPath(FSURL.appPlugins.path): return "plugins"
        case Self.normalizedContainerPath(FSURL.internalDaemons.path): return "daemons"
        case Self.normalizedContainerPath(FSURL.sysGroup.path): return "systemGroups"
        default: return nil
        }
    }

    private var isRestrictedContainerRoot: Bool { restrictedContainerRootKind != nil }

    /// Snapshot Airlift's published metadata on the main actor before starting
    /// filesystem work. The background worker must not read SwiftUI environment state.
    private func restrictedContainerMetadataPaths(for rootKind: String?) -> [String] {
        switch rootKind {
        case "data":
            return airlift.installedAppContainers.map(\.container)
        case "appGroups":
            return airlift.installedAppGroups.map(\.container)
        case "plugins":
            return airlift.installationProxyPluginKitPluginPaths.map(\.path)
        case "daemons":
            return airlift.installationProxyInternalDaemonPaths.map(\.path)
        default:
            return []
        }
    }

    /// DB5+ Airlift lists directory names from captured InstallationProxy metadata
    /// when available, and otherwise falls back to read-only directory enumeration.
    private static func restrictedContainerPaths(
        rootKind: String,
        rootURL: URL,
        metadataPaths: [String],
        maxInodeLimit: Int64
    ) throws -> [String] {
        var paths = Set(metadataPaths.map { Self.normalizedContainerPath($0) })
        do {
            let directChildren = try fm.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            for child in directChildren {
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory { paths.insert(Self.normalizedContainerPath(child.standardizedFileURL.path)) }
            }
        } catch {
            if paths.isEmpty {
                // If ordinary enumeration is denied and InstallationProxy has not
                // supplied paths yet, retain path-only UUID enumeration. These rows
                // remain labels only and cannot open the individual container.
                let enumeratedPaths = fsHandlers.getDirPaths(rootURL.path, maxInode: maxInodeLimit)
                for candidate in enumeratedPaths {
                    let normalized = Self.normalizedContainerPath(candidate)
                    let url = URL(fileURLWithPath: normalized)
                    guard url.deletingLastPathComponent().standardizedFileURL.path == rootURL.standardizedFileURL.path else { continue }
                    if rootKind != "systemGroups", UUID(uuidString: url.lastPathComponent) == nil { continue }
                    paths.insert(normalized)
                }
                if paths.isEmpty { throw error }
            }
        }

        // If ordinary enumeration succeeded but could not see the sandboxed root,
        // use the same names-only fallback to populate locked identifier rows.
        if paths.isEmpty {
            let enumeratedPaths = fsHandlers.getDirPaths(rootURL.path, maxInode: maxInodeLimit)
            for candidate in enumeratedPaths {
                let normalized = Self.normalizedContainerPath(candidate)
                let url = URL(fileURLWithPath: normalized)
                guard url.deletingLastPathComponent().standardizedFileURL.path == rootURL.standardizedFileURL.path else { continue }
                if rootKind != "systemGroups", UUID(uuidString: url.lastPathComponent) == nil { continue }
                paths.insert(normalized)
            }
        }
        return paths.sorted()
    }

    private static func makeRestrictedContainerItem(path value: String) -> FileItem {
        let url = URL(fileURLWithPath: value, isDirectory: true)
        var item = getFileItem(at: url)
        item.name = url.lastPathComponent
        item.destURL = url
        item.type = .folder
        return item
    }

    private func restrictedContainerDisplayName(for file: FileItem) -> String {
        guard let kind = restrictedContainerRootKind else { return file.name }
        let path = Self.normalizedContainerPath(file.fileURL.standardizedFileURL.path)
        switch kind {
        case "data":
            return airlift.installedAppContainers.first(where: {
                Self.normalizedContainerPath($0.container) == path
            })?.bundleID ?? URL(fileURLWithPath: path).lastPathComponent
        case "appGroups":
            if let group = airlift.installedAppGroups.first(where: { candidate in
                Self.normalizedContainerPath(candidate.container) == path
            }) {
                // Keep this work in concrete sub-expressions: nesting filter + Set +
                // Array + sorted inside the large FileBrowserView expression makes
                // Swift's type checker time out in Release builds.
                let nonEmptySourceApps: [String] = group.sourceApps.filter { sourceApp in
                    !sourceApp.isEmpty
                }
                let uniqueSourceApps: Set<String> = Set(nonEmptySourceApps)
                let bundleIDs: [String] = uniqueSourceApps.sorted()
                if !bundleIDs.isEmpty {
                    return bundleIDs.joined(separator: ", ")
                }
            }
            return URL(fileURLWithPath: path).lastPathComponent
        default:
            return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private func reloadRestrictedContainerRoot() {
        guard isRestrictedContainerRoot else { return }
        hasLoaded = false
        loadFilesFromPath()
    }
    
    /// Keep the loading row in its own view so the compiler does not have to
    /// infer it as part of FileBrowserView's already large List expression.
    private var loadingFilesSection: some View {
        Section {
            VStack(alignment: .leading) {
                HStack {
                    ProgressView()
                        .offset(y: 0.5)
                    Text("Loading Files...")
                        .fontWeight(.medium)
                }
                if isContainer {
                    containerLoadingNote
                }
            }
        }
    }

    private var containerLoadingNote: some View {
        Text("These files could take 30 seconds or longer to load, since the method of getting container paths is very slow.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    var body: some View {
        List {
            if isLoading {
                loadingFilesSection
            } else if showFailure {
                CompactAlert(title: "Failed to load files from directory!", symbol: "folder.badge.questionmark", text: failMsg)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } else {
                ForEach(visibleFiles) { file in
                    FileBrowserItemRow(
                        file: file,
                        shouldGrant: shouldGrant,
                        isContainer: isContainer,
                        readOnly: effectiveReadOnly,
                        airliftRemoteRoot: airliftRemoteRoot,
                        airliftLocalRoot: airliftLocalRoot,
                        localBasePath: path.path,
                        displayName: isRestrictedContainerRoot ? restrictedContainerDisplayName(for: file) : nil,
                        navigationBlocked: isRestrictedContainerRoot
                    )
                }
            }
        }
        .navigationTitle(navigationTitleOverride ?? path.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .customListStyle(listStyle)
        .adaptiveListMargin()
        .searchable(text: $searchText)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(FileSortMode.allCases, id: \.self) { option in
                        Button {
                            chosenSort = option
                        } label: {
                            if chosenSort == option {
                                Label(option.label, systemImage: "checkmark")
                                    .tag(option)
                            } else {
                                Text(option.label)
                                    .tag(option)
                            }
                        }
                    }
                    Divider()
                    Button {
                        filesAscend.toggle()
                    } label: {
                        if filesAscend {
                            Label("Ascending", systemImage: "chevron.up")
                        } else {
                            Label("Descending", systemImage: "chevron.down")
                        }
                    }
                    .disabled(chosenSort == .system)
                } label: {
                    Label("Sort", systemImage: "line.3.horizontal.decrease")
                }
                .labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !isContainer && !effectiveReadOnly {
                        Menu {
                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new file? Make sure you attach an extension at the end.", placeholder: "new.txt", completion: { name in
                                    let name = name ?? ""
                                    guard !name.isEmpty else { return }
                                    if hasAirliftWriteContext && !remoteMutationAllowed() {
                                        Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                        return
                                    }
                                    let fileURL = path.appendingPathComponent(name)
                                    do {
                                        try Data().write(to: fileURL)
                                    } catch {
                                        Alertinator.shared.alert(title: "Failed to create file!", body: error.localizedDescription)
                                        return
                                    }
                                    guard let remotePath = remotePath(for: fileURL) else {
                                        mgr.refreshFiles.toggle()
                                        return
                                    }
                                    Task {
                                        let ok = await AirliftBridge.shared.writeBack(localURL: fileURL, remotePath: remotePath)
                                        await MainActor.run {
                                            if ok {
                                                mgr.refreshFiles.toggle()
                                            } else {
                                                try? fm.removeItem(at: fileURL)
                                                Alertinator.shared.alert(title: "Failed to create file!", body: "The remote Airlift write failed. Check the Airlift log.")
                                            }
                                        }
                                    }
                                })
                            } label: {
                                Label("File", systemImage: "doc")
                            }
                            
                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new property list?", placeholder: "Plist Name", completion: { name in
                                    let name = name ?? ""
                                    guard !name.isEmpty else { return }
                                    if hasAirliftWriteContext && !remoteMutationAllowed() {
                                        Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                        return
                                    }
                                    let fileURL = path.appendingPathComponent(name + ".plist")
                                    do {
                                        let data = try PropertyListSerialization.data(fromPropertyList: NSMutableDictionary(), format: .xml, options: 0)
                                        try data.write(to: fileURL)
                                    } catch {
                                        Alertinator.shared.alert(title: "Failed to create property list!", body: error.localizedDescription)
                                        return
                                    }
                                    guard let remotePath = remotePath(for: fileURL) else {
                                        mgr.refreshFiles.toggle()
                                        return
                                    }
                                    Task {
                                        let ok = await AirliftBridge.shared.writeBack(localURL: fileURL, remotePath: remotePath)
                                        await MainActor.run {
                                            if ok {
                                                mgr.refreshFiles.toggle()
                                            } else {
                                                try? fm.removeItem(at: fileURL)
                                                Alertinator.shared.alert(title: "Failed to create property list!", body: "The remote Airlift write failed. Check the Airlift log.")
                                            }
                                        }
                                    }
                                })
                            } label: {
                                Label("Property List", systemImage: "tablecells")
                            }
                            
                            Button {
                                Alertinator.shared.prompt(title: "What would you like to call your new folder?", placeholder: "Folder Name", completion: { name in
                                    let name = name ?? ""
                                    guard !name.isEmpty else { return }
                                    if hasAirliftWriteContext && !remoteMutationAllowed() {
                                        Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                        return
                                    }
                                    let folderURL = path.appendingPathComponent(name, isDirectory: true)
                                    do {
                                        try fm.createDirectory(at: folderURL, withIntermediateDirectories: false)
                                    } catch {
                                        Alertinator.shared.alert(title: "Failed to create folder!", body: error.localizedDescription)
                                        return
                                    }
                                    guard let remotePath = remotePath(for: folderURL) else {
                                        mgr.refreshFiles.toggle()
                                        return
                                    }
                                    Task {
                                        let ok = await AirliftBridge.shared.createRemoteDirectory(localURL: folderURL, remotePath: remotePath)
                                        await MainActor.run {
                                            if ok {
                                                mgr.refreshFiles.toggle()
                                            } else {
                                                try? fm.removeItem(at: folderURL)
                                                Alertinator.shared.alert(title: "Failed to create folder!", body: "The remote Airlift directory creation failed. Check the Airlift log.")
                                            }
                                        }
                                    }
                                })
                            } label: {
                                Label("Folder", systemImage: "folder")
                            }
                            
                            Button {
                                Alertinator.shared.prompt(title: "Where would you like your new symlink to point to?", placeholder: "/path/to/dir", completion: { symPath in
                                    let symPath = symPath ?? ""
                                    guard !symPath.isEmpty else { return }
                                    if hasAirliftWriteContext {
                                        Alertinator.shared.alert(title: "Symlink write unavailable", body: "The current Airlift write API does not preserve a new symbolic link, so no local or remote change was made.")
                                        return
                                    }
                                    do {
                                        try fm.createSymbolicLink(atPath: path.appendingPathComponent(URL(fileURLWithPath: symPath).lastPathComponent).path, withDestinationPath: symPath)
                                        mgr.refreshFiles.toggle()
                                    } catch {
                                        Alertinator.shared.alert(title: "Failed to create symlink!", body: error.localizedDescription)
                                    }
                                })
                            } label: {
                                Label("Symlink", systemImage: "arrow.up.right.circle")
                            }
                        } label: {
                            Label("New...", systemImage: "plus")
                        }
                        
                        Button {
                            showFileImporter.toggle()
                        } label: {
                            Label("Import File", systemImage: "arrow.down.doc")
                        }
                        Divider()
                    }
                    Button {
                        Alertinator.shared.prompt(
                            title: "Go to Path",
                            placeholder: "",
                            text: path.path
                        ) { enteredPath in
                            guard let enteredPath else { return }
                            let rawPath = enteredPath.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard rawPath.hasPrefix("/") else {
                                Alertinator.shared.alert(title: "Invalid Path", body: "Enter an absolute path beginning with '/'.")
                                return
                            }

                            let target = URL(fileURLWithPath: rawPath).standardizedFileURL
                            guard fm.fileExists(atPath: target.path) else {
                                Alertinator.shared.alert(title: "Path Not Found", body: "No file or folder exists at:\n\(target.path)")
                                return
                            }

                            if SystemReadOnlyAccess.isSystemPath(target) && !SystemReadOnlyAccess.canReadPath(target) {
                                Alertinator.shared.alert(title: "Path Not Readable", body: "Erosion cannot read this system path from the current process.")
                                return
                            }
                            if !SystemReadOnlyAccess.isSystemPath(target) && !fm.isReadableFile(atPath: target.path) {
                                Alertinator.shared.alert(title: "Path Not Readable", body: "The current process cannot read this path.")
                                return
                            }

                            let isDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                            if isDirectory {
                                pathJumpDestination = target
                            } else {
                                jumpFileURL = target
                                showJumpFile = true
                            }
                        }
                    } label: {
                        Label("Go to Path", systemImage: "arrow.turn.down.right")
                    }
                    NavigationLink {
                        FileBrowserView(path: URL.documentsDirectory)
                    } label: {
                        Label("Open App Docs", systemImage: "folder")
                    }
                    NavigationLink {
                        List {
                            Section {
                                HStack {
                                    Text("Max Inode")
                                    TextField("7500000", value: $maxInode, format: .number)
                                        .multilineTextAlignment(.trailing)
                                }
                            } header: {
                                HeaderLabel("Container Fetching", symbol: "externaldrive")
                            } footer: {
                                Text("This controls how quickly files can load. Lower values = faster fetching but less files.")
                            }
                            
                            Section {
                                Picker("List Style", selection: $listStyle) {
                                    Text("Default").tag(1)
                                    Text("Plain").tag(2)
                                    Text("Grouped").tag(3)
                                }
                                Toggle("Hide Dates", isOn: $hideDates)
                            } header: {
                                HeaderLabel("View Options", symbol: "eye")
                            }
                            
                            Section {
                                Stepper(value: $textViewerSize) {
                                    HStack {
                                        Text("Text Size")
                                        Spacer()
                                        Text(textViewerSize.description)
                                    }
                                }
                                Toggle("Monospaced Font", isOn: $useMonospaced)
                            } header: {
                                HeaderLabel("Text Viewer", symbol: "doc.plaintext")
                            }
                        }
                        .navigationTitle("File Browser Settings")
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Label("Actions", systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
        .navigationDestination(item: $pathJumpDestination) { target in
            FileBrowserPathDestination(url: target)
                .environmentObject(mgr)
        }
        .sheet(isPresented: $showJumpFile, onDismiss: { jumpFileURL = nil }) {
            if let target = jumpFileURL {
                FilePathJumpViewer(url: target)
                    .environmentObject(mgr)
            }
        }
        .refreshable {
            mgr.refreshFiles.toggle()
        }
        .onAppear {
            if isRestrictedContainerRoot {
                airlift.maybeAutoScanInstalledAppContainers()
            }
            if hasLoaded {
                return
            }
            if !mgr.storedFiles.isEmpty && mgr.storedURL == path && !isRestrictedContainerRoot {
                unfilteredFiles = sortFiles(files: mgr.storedFiles)
            } else if isContainer && hasLoaded {
                // do nothing as it's already being stored in the variable
            } else {
                if fixedFiles != nil {
                    // Fixed-file views intentionally do not require the parent directory
                    // itself to be listable. Each supplied URL is handled as a file.
                    loadFilesFromPath()
                } else if isAirliftSnapshot {
                    // The snapshot lives in Erosion's own temporary container,
                    // so POSIX access to the original /var/mobile system path
                    // is irrelevant here. Keep the browser read-only while
                    // allowing normal local enumeration of the recovered tree.
                    loadFilesFromPath()
                } else if isContainer {
                    // Container roots use the existing BadQuery path enumerator.
                    // This branch must precede the normal read-only filesystem gate,
                    // so compatibility-mode users can open the container listing.
                    loadFilesFromPath()
                } else if shouldGrant {
                    // Explicit container navigation may request the existing BadQuery
                    // access path even when the screen itself is read-only. This grants
                    // listing access only; readOnly continues to disable UI mutations.
                    let res = bq.grantAccess(atPath: path.path)
                    if res.0 {
                        loadFilesFromPath()
                    } else {
                        showFailure = true
                        failMsg = "You don't have permission to view this directory."
                    }
                } else if effectiveReadOnly {
                    if SystemReadOnlyAccess.canReadDirectory(path) {
                        loadFilesFromPath()
                    } else {
                        showFailure = true
                        failMsg = "This system path is not readable by the current process."
                    }
                } else {
                    loadFilesFromPath()
                }
            }
        }
        .onChange(of: chosenSort) {
            loadFilesFromPath()
        }
        .onChange(of: filesAscend) {
            loadFilesFromPath()
        }
        .onChange(of: mgr.refreshFiles) {
            loadFilesFromPath()
        }
        .onChange(of: airlift.installedAppContainers) { _, _ in
            reloadRestrictedContainerRoot()
        }
        .onChange(of: airlift.installedAppGroups) { _, _ in
            reloadRestrictedContainerRoot()
        }
        .onChange(of: airlift.installationProxyInternalDaemonPaths) { _, _ in
            reloadRestrictedContainerRoot()
        }
        .onChange(of: airlift.installationProxyPluginKitPluginPaths) { _, _ in
            reloadRestrictedContainerRoot()
        }
    }
    
    // MARK: handle files
    private func loadFilesFromPath() {
        // Metadata can be published in several updates when InstallationProxy
        // completes. Only the newest directory request may commit its result.
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        let requestedPath = path
        let fixedPathItems = fixedFiles
        let containerMode = isContainer
        let maxInodeLimit = Int64(maxInode)
        let restrictedRootKind = restrictedContainerRootKind
        let restrictedMetadataPaths = restrictedContainerMetadataPaths(for: restrictedRootKind)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var unsortedFiles: [FileItem] = []
                if let rootKind = restrictedRootKind {
                    let paths = try Self.restrictedContainerPaths(
                        rootKind: rootKind,
                        rootURL: requestedPath,
                        metadataPaths: restrictedMetadataPaths,
                        maxInodeLimit: maxInodeLimit
                    )
                    unsortedFiles = paths.map { Self.makeRestrictedContainerItem(path: $0) }
                } else if let fixedPathItems {
                    unsortedFiles = fixedPathItems.map { getFileItem(at: $0) }
                } else if containerMode {
                    let paths = fsHandlers.getDirPaths(requestedPath.path, maxInode: maxInodeLimit)
                    for path in paths {
                        unsortedFiles.append(getFileItem(at: URL(fileURLWithPath: path), isContainer: true))
                    }
                } else {
                    let pathFiles = try fm.contentsOfDirectory(
                        at: requestedPath,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
                    )
                    unsortedFiles = pathFiles.map { fileURL in
                        if requestedPath == FSURL.appGroup || requestedPath == FSURL.systemData {
                            return getFileItem(at: fileURL, isContainer: true)
                        }
                        return getFileItem(at: fileURL)
                    }
                }

                DispatchQueue.main.async {
                    guard self.loadGeneration == generation else { return }
                    self.unfilteredFiles = self.sortFiles(files: unsortedFiles)
                    if containerMode {
                        self.mgr.storedFiles = unsortedFiles
                        self.mgr.storedURL = requestedPath
                    }
                    self.hasLoaded = true
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.loadGeneration == generation else { return }
                    print("(fm) failed to load files from \(requestedPath): \(error.localizedDescription)")
                    self.showFailure = true
                    self.failMsg = "You may not have permission to view this directory. Check error logs for more detailed info."
                    self.isLoading = false
                }
            }
        }
    }
    

    private func sortFiles(files: [FileItem]) -> [FileItem] {
        var sortedFiles: [FileItem]
        
        switch chosenSort {
        case .system:
            sortedFiles = files
        case .name:
            sortedFiles = files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date:
            sortedFiles = files.sorted { $0.modifiedDate > $1.modifiedDate }
        case .type:
            sortedFiles = files.sorted { $0.type.sortOrder < $1.type.sortOrder }
        case .size:
            sortedFiles = files.sorted { $0.size < $1.size }
        }

        sortedFiles = filesAscend ? sortedFiles : sortedFiles.reversed()
        sortedFiles = sortedFiles.sorted { a, b in
            a.hidden && !b.hidden
        }
        return sortedFiles
    }
    
    // MARK: handle import
    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let fileURL):
            let stopAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if stopAccess { fileURL.stopAccessingSecurityScopedResource() }
            }

            if hasAirliftWriteContext && !remoteMutationAllowed() {
                Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                return
            }

            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let newURL = path.appendingPathComponent(fileURL.lastPathComponent, isDirectory: isDirectory)
            do {
                if fm.fileExists(atPath: newURL.path) {
                    throw NSError(domain: "Erosion.FileBrowser", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "A file with this name already exists."])
                }
                try fm.copyItem(at: fileURL, to: newURL)
            } catch {
                print("(fm) failed to import file: \(error.localizedDescription)")
                Alertinator.shared.alert(title: "Failed to import file!", body: error.localizedDescription)
                return
            }

            guard let remotePath = remotePath(for: newURL) else {
                mgr.refreshFiles.toggle()
                return
            }

            Task {
                let ok: Bool
                if isDirectory {
                    ok = await AirliftBridge.shared.createRemoteDirectory(localURL: newURL, remotePath: remotePath)
                } else {
                    ok = await AirliftBridge.shared.writeBack(localURL: newURL, remotePath: remotePath)
                }
                await MainActor.run {
                    if ok {
                        mgr.refreshFiles.toggle()
                    } else {
                        try? fm.removeItem(at: newURL)
                        Alertinator.shared.alert(title: "Failed to import file!", body: "The remote Airlift write failed. Check the Airlift log.")
                    }
                }
            }

        case .failure(let error):
            print("(fm) failed to import file: \(error.localizedDescription)")
            Alertinator.shared.alert(title: "Failed to import file!", body: error.localizedDescription)
        }
    }

}

// MARK: user interface
extension View {
    @ViewBuilder
    func customListStyle(_ selection: Int) -> some View {
        switch selection {
        case 2: self.listStyle(.inset)
        case 3: self.listStyle(.grouped)
        default: self.listStyle(.insetGrouped)
        }
    }
    
    @ViewBuilder
    func adaptiveListMargin() -> some View {
        if #available(iOS 26.0, *) {
            self.contentMargins(.top, 1)
        }
    }
}

private struct FileBrowserPathDestination: View {
    let url: URL

    var body: some View {
        FileBrowserView(
            path: url,
            readOnly: SystemReadOnlyAccess.isReadOnly(url),
            navigationTitleOverride: url.path == "/" ? "/" : url.lastPathComponent
        )
    }
}

private struct FilePathJumpViewer: View {
    let url: URL

    var body: some View {
        Group {
            if conformsToPlistViewer(url) {
                PlistViewer(url)
            } else if conformsToTextViewer(url) {
                TextViewer(url)
            } else {
                NavigationStack {
                    FilePreviewView(url: url)
                }
            }
        }
    }
}

