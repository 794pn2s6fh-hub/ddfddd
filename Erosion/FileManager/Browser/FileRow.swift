//
//  FileRow.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI

import QuickLook
import ZIPFoundation

struct FileRow: View {
    private static let extendedPreviewExtensions: Set<String> = [
        "dylib", "bin", "so", "o", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff",
        "gif", "webp", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aif", "caf",
        "flac", "aac", "pdf", "svg", "car", "deb"
    ]
    private static let binaryPreviewExtensions: Set<String> = ["dylib", "bin", "so", "o", "deb"]
    private static let textFileExtensions: Set<String> = [
        "txt", "text", "log", "md", "markdown", "json", "xml", "strings", "stringsdict",
        "yaml", "yml", "conf", "cfg", "ini", "csv", "tsv", "sh", "bash", "zsh", "py",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "js", "jsx", "ts", "tsx",
        "html", "htm", "css", "sql", "entitlements", "mobileprovision"
    ]

    @EnvironmentObject var mgr: ErosionManager
    @AppStorage("hideDates") var hideDates = false
    var file: FileItem
    var readOnly: Bool = false
    var airliftRemotePath: String? = nil
    var airliftRemoteRoot: String? = nil
    var airliftLocalRoot: String? = nil
    var selectionMode: Bool = false
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    var onSelectionAction: (FileBrowserSelectionAction) -> Void = { _ in }
    
    @State private var conformsText = false
    @State private var conformsPlist = false
    
    @State private var showInfo = false
    @State private var showPlistViewer = false
    @State private var showTextViewer = false
    @State private var showExtendedPreview = false
    @State private var previewURL: URL?
    @State private var virtualPreviewURL: URL?
    @State private var virtualPreviewDirectory: URL?
    @State private var isPreparingVirtualPreview = false
    @State private var isPerformingVirtualFileAction = false
    
    private var supportsExtendedPreview: Bool {
        Self.extendedPreviewExtensions.contains(fileExtension)
    }

    private var isBinaryPreview: Bool {
        Self.binaryPreviewExtensions.contains(fileExtension)
    }

    private var fileExtension: String {
        file.fileURL.pathExtension.lowercased()
    }

    private var isKnownPlist: Bool {
        fileExtension == "plist"
    }

    private var isKnownText: Bool {
        Self.textFileExtensions.contains(fileExtension) || file.uttype.conforms(to: .text)
    }

    private var isZipFile: Bool {
        fileExtension == "zip" || file.uttype.conforms(to: .zip)
    }

    private var canViewPlist: Bool { conformsPlist || isKnownPlist }
    // SVGs are image documents, even though Uniform Type Identifiers may also
    // classify their XML payload as text. Route them to the image viewer.
    // Binary packages and dynamic libraries stay in the hex viewer; do not
    // offer a second plain-text viewer for these two extensions.
    private var canViewText: Bool {
        !["dylib", "deb"].contains(fileExtension)
            && fileExtension != "svg"
            && (conformsText || isKnownText)
    }

    /// Content sniffing is intentionally deferred until a user opens an unknown
    /// extension. Doing it from onAppear caused every file in a large directory
    /// to be read twice just to populate its row.
    private func openStandardFile() {
        if isZipFile && !readOnly {
            uncompressFileAndSync()
        } else if isBinaryPreview || supportsExtendedPreview {
            showExtendedPreview = true
        } else if isKnownPlist {
            // A .plist extension gets the structured viewer only when its root
            // is actually a dictionary. Malformed/text plist files fall back to text.
            let isPlist = conformsToPlistViewer(file.fileURL)
            let isText = !isPlist && conformsToTextViewer(file.fileURL)
            conformsPlist = isPlist
            conformsText = isText
            if isPlist {
                showPlistViewer = true
            } else if isText {
                showTextViewer = true
            } else {
                previewURL = file.fileURL
            }
        } else if isKnownText {
            // Known text files must be classified as text, not as scalar Property Lists.
            let isText = conformsToTextViewer(file.fileURL)
            conformsPlist = false
            conformsText = isText
            if isText {
                showTextViewer = true
            } else {
                previewURL = file.fileURL
            }
        } else {
            // For unknown extensions, detect a real dictionary plist first,
            // then UTF-8 text. Do not treat any parseable plist scalar as a plist.
            let isPlist = conformsToPlistViewer(file.fileURL)
            let isText = !isPlist && conformsToTextViewer(file.fileURL)
            conformsPlist = isPlist
            conformsText = isText
            if isPlist {
                showPlistViewer = true
            } else if isText {
                showTextViewer = true
            } else {
                previewURL = file.fileURL
            }
        }
    }

    private var isAirliftRemote: Bool {
        airliftRemotePath != nil && airliftRemoteRoot != nil && airliftLocalRoot != nil
    }

    private var isCoreMediaVirtualFile: Bool {
        CoreMediaUsrLibexecReader.containsVirtualPath(file.fileURL)
    }

    /// Materializes a read-only CoreMedia file into the app's temporary directory,
    /// then routes it through Erosion's existing generic viewers.
    @MainActor
    private func openVirtualFileWithStandardViewer() {
        guard !isPreparingVirtualPreview else { return }
        isPreparingVirtualPreview = true

        let remotePath = file.fileURL.path
        Task { @MainActor in
            defer { isPreparingVirtualPreview = false }
            var newDirectory: URL?
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try CoreMediaUsrLibexecReader.readFileData(atPath: remotePath)
                }.value

                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ErosionVirtualPreviews", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                newDirectory = directory
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let localURL = directory.appendingPathComponent(URL(fileURLWithPath: remotePath).lastPathComponent)
                try data.write(to: localURL, options: .atomic)

                let previousDirectory = virtualPreviewDirectory
                virtualPreviewDirectory = directory
                virtualPreviewURL = localURL
                if let previousDirectory {
                    try? FileManager.default.removeItem(at: previousDirectory)
                }

                conformsPlist = conformsToPlistViewer(localURL)
                conformsText = conformsToTextViewer(localURL)

                if isBinaryPreview || supportsExtendedPreview {
                    showExtendedPreview = true
                } else if conformsPlist {
                    showPlistViewer = true
                } else if conformsText {
                    showTextViewer = true
                } else {
                    previewURL = localURL
                }
            } catch {
                if let newDirectory {
                    try? FileManager.default.removeItem(at: newDirectory)
                }
                if CoreMediaUsrLibexecReader.shouldSuggestAppReopen(for: error, at: URL(fileURLWithPath: remotePath)) {
                    Alertinator.shared.alert(title: "Restart Erosion", body: CoreMediaUsrLibexecReader.reopenAppMessage)
                } else {
                    Alertinator.shared.alert(title: "Unable to Open File", body: error.localizedDescription)
                }
            }
        }
    }

    private var viewerFileURL: URL {
        virtualPreviewURL ?? file.fileURL
    }

    private func remoteSiblingPath(_ name: String) -> String? {
        guard let airliftRemotePath else { return nil }
        return URL(fileURLWithPath: airliftRemotePath)
            .deletingLastPathComponent()
            .appendingPathComponent(name)
            .path
    }

    private func remoteMutationAllowed() -> Bool {
        AirliftBridge.shared.fileBrowserWriteReady()
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.clear)
            Circle()
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.7), lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }

    var body: some View {
        Group {
            if file.type == .file {
                Button {
                    if selectionMode {
                        onSelect()
                    } else if isCoreMediaVirtualFile {
                        openVirtualFileWithStandardViewer()
                    } else {
                        openStandardFile()
                    }
                } label: {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        if selectionMode {
                            selectionIndicator
                        }

                        Group {
                            if isPreparingVirtualPreview {
                                ProgressView()
                            } else {
                                Image(systemName: "doc")
                            }
                        }
                        .frame(width: 20, alignment: .center)
                        .foregroundStyle(file.hidden ? .secondary : .primary)
                        
                        VStack(alignment: .leading) {
                            Text(file.name)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file {
                                Text(file.modifiedDateStr)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        if !selectionMode {
                            if file.type == .file {
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity)
                            }
                            Button {
                                showInfo.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                            }
                            .buttonStyle(.plain)
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
                }
            } else {
                if selectionMode {
                    Button(action: onSelect) {
                        HStack(spacing: isSolariumUI() ? 12 : 10) {
                            selectionIndicator
                            Image(systemName: "arrow.up.right.circle")
                                .frame(width: 20, alignment: .center)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                            Text(file.name)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(destination: FileBrowserView(
                        path: file.destURL,
                        readOnly: readOnly,
                        airliftRemoteRoot: airliftRemoteRoot,
                        airliftLocalRoot: airliftLocalRoot
                    )) {
                        HStack(spacing: isSolariumUI() ? 12 : 10) {
                            Image(systemName: "arrow.up.right.circle")
                                .frame(width: 20, alignment: .center)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                            Text(file.name)
                                .foregroundStyle(file.hidden ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .foregroundStyle(Color(.label))
        .animation(.easeInOut(duration: 0.2), value: selectionMode)
        .sheet(isPresented: $showInfo) {
            InfoViewer(file, pathOverride: airliftRemotePath)
        }
        .sheet(isPresented: $showPlistViewer, onDismiss: cleanupVirtualPreview) {
            PlistViewer(viewerFileURL, remotePath: airliftRemotePath, readOnly: isCoreMediaVirtualFile)
        }
        .sheet(isPresented: $showTextViewer, onDismiss: cleanupVirtualPreview) {
            TextViewer(viewerFileURL, remotePath: airliftRemotePath, readOnly: isCoreMediaVirtualFile)
        }
        .sheet(isPresented: $showExtendedPreview, onDismiss: cleanupVirtualPreview) {
            NavigationStack {
                FilePreviewView(url: viewerFileURL, remotePath: airliftRemotePath, remoteWritable: !readOnly && isAirliftRemote)
            }
        }
        .onDisappear(perform: cleanupVirtualPreview)
        .onChange(of: previewURL) { newValue in
            if newValue == nil { cleanupVirtualPreview() }
        }
        .quickLookPreview($previewURL)
        // MARK: cell actions
        .contextMenu {
            if selectionMode {
                Button { onSelectionAction(.copy) } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { onSelectionAction(.share) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button { onSelectionAction(.zip) } label: { Label("Zip", systemImage: "archivebox") }
                if !readOnly {
                    Button(role: .destructive) { onSelectionAction(.delete) } label: { Label("Delete", systemImage: "trash") }
                }
            } else {
            if isCoreMediaVirtualFile {
                Button {
                    openVirtualFileWithStandardViewer()
                } label: {
                    Label("Preview", systemImage: "doc.text.magnifyingglass")
                }
            } else if canViewText || canViewPlist || supportsExtendedPreview {
                Menu {
                    Button {
                        previewURL = file.fileURL
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                    }
                    
                    if supportsExtendedPreview {
                        Button {
                            showExtendedPreview = true
                        } label: {
                            Label("Extended Viewer", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                    if canViewPlist {
                        Button {
                            showPlistViewer.toggle()
                        } label: {
                            Label("Plist Viewer", systemImage: "tablecells")
                        }
                    }
                    
                    if canViewText {
                        Button {
                            showTextViewer.toggle()
                        } label: {
                            Label("Text Viewer", systemImage: "doc.plaintext")
                        }
                    }
                } label: {
                    Label("View In...", systemImage: "doc.text.magnifyingglass")
                }
            } else {
                Button {
                    if supportsExtendedPreview {
                        showExtendedPreview = true
                    } else {
                        openStandardFile()
                    }
                } label: {
                    Label("Preview", systemImage: "doc.text.magnifyingglass")
                }
            }
            
            Divider()
            
            Button {
                showInfo.toggle()
            } label: {
                Label("Get Info", systemImage: "info.circle")
            }
            
            if file.type == .file && !readOnly {
                Button {
                    Alertinator.shared.prompt(title: "What would you like to call this file?", placeholder: file.name, completion: { result in
                        if let name = result {
                            let oldURL = file.fileURL
                            let newURL = oldURL.deletingLastPathComponent().appendingPathComponent(name)
                            if fm.fileExists(atPath: newURL.path) {
                                Alertinator.shared.alert(title: "Failed to rename file!", body: "A file with that name already exists.")
                                return
                            }

                            if isAirliftRemote {
                                guard remoteMutationAllowed(), let oldRemote = airliftRemotePath, let newRemote = remoteSiblingPath(name) else {
                                    Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
                                    return
                                }
                                do {
                                    try fm.copyItem(at: oldURL, to: newURL)
                                } catch {
                                    Alertinator.shared.alert(title: "Failed to rename file!", body: error.localizedDescription)
                                    return
                                }

                                Task {
                                    let wrote = await AirliftBridge.shared.writeBack(localURL: newURL, remotePath: newRemote)
                                    var deletedOld = false
                                    if wrote {
                                        deletedOld = await AirliftBridge.shared.removeRemotePath(oldRemote)
                                        if !deletedOld {
                                            _ = await AirliftBridge.shared.removeRemotePath(newRemote)
                                        }
                                    }
                                    await MainActor.run {
                                        if wrote && deletedOld {
                                            try? fm.removeItem(at: oldURL)
                                            mgr.refreshFiles.toggle()
                                        } else {
                                            try? fm.removeItem(at: newURL)
                                            Alertinator.shared.alert(title: "Failed to rename file!", body: "The remote Airlift rename failed. Check the Airlift log.")
                                        }
                                    }
                                }
                            } else {
                                let res = renameFile(oldURL, to: name)
                                if res {
                                    mgr.refreshFiles.toggle()
                                } else {
                                    Alertinator.shared.alert(title: "Failed to rename file!", body: Errors.checkLogs)
                                }
                            }
                        }
                    })
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            
            if file.type == .file && !readOnly {
                if isZipFile {
                    Button {
                        uncompressFileAndSync()
                    } label: {
                        Label("Uncompress", systemImage: "archivebox")
                    }
                } else {
                    Button {
                        compressFileAndSync()
                    } label: {
                        Label("Compress", systemImage: "archivebox")
                    }
                }
            }
            
            if file.type == .file && !readOnly {
                Button {
                    duplicateFileAndSync()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }
            
            Divider()
            
            Button {
                if isCoreMediaVirtualFile {
                    loadVirtualFileForAction { data in
                        guard copyDataToClipboard(data, fileName: file.name) else {
                            Alertinator.shared.alert(title: "Failed to copy file!", body: Errors.checkLogs)
                            return
                        }
                    }
                } else if !copyFileToClipboard(file.fileURL) {
                    Alertinator.shared.alert(title: "Failed to copy file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            
            Button {
                if isCoreMediaVirtualFile {
                    loadVirtualFileForAction { data in
                        presentShareSheet(with: data, fileName: file.name)
                    }
                } else if let url = makeTemp(file.fileURL) {
                    presentShareSheet(with: url)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            
            Divider()
            
            if !readOnly {
                Button(role: .destructive) {
                    deleteFileAndSync()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            }
        }
    }

    @MainActor
    private func loadVirtualFileForAction(_ action: @escaping (Data) -> Void) {
        guard !isPerformingVirtualFileAction else { return }
        isPerformingVirtualFileAction = true
        let path = file.fileURL.path
        Task { @MainActor in
            defer { isPerformingVirtualFileAction = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try CoreMediaUsrLibexecReader.readFileData(atPath: path)
                }.value
                action(data)
            } catch {
                if CoreMediaUsrLibexecReader.shouldSuggestAppReopen(for: error, at: URL(fileURLWithPath: path)) {
                    Alertinator.shared.alert(title: "Restart Erosion", body: CoreMediaUsrLibexecReader.reopenAppMessage)
                } else {
                    Alertinator.shared.alert(title: "File Action Failed", body: error.localizedDescription)
                }
            }
        }
    }

    private func cleanupVirtualPreview() {
        if let directory = virtualPreviewDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        virtualPreviewDirectory = nil
        virtualPreviewURL = nil
    }

    private func compressFileAndSync() {
        if isAirliftRemote && !remoteMutationAllowed() {
            Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
            return
        }
        let sourceURL = file.fileURL
        let zipURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent(sourceURL.lastPathComponent + ".zip")
        guard !fm.fileExists(atPath: zipURL.path) else {
            Alertinator.shared.alert(title: "Failed to compress file!", body: "An archive with that name already exists.")
            return
        }
        guard zipFile(sourceURL) else {
            Alertinator.shared.alert(title: "Failed to compress file!", body: Errors.checkLogs)
            return
        }

        guard isAirliftRemote, let remotePath = remoteSiblingPath(zipURL.lastPathComponent) else {
            mgr.refreshFiles.toggle()
            return
        }
        Task {
            let ok = await AirliftBridge.shared.writeBack(localURL: zipURL, remotePath: remotePath)
            await MainActor.run {
                if ok {
                    mgr.refreshFiles.toggle()
                } else {
                    try? fm.removeItem(at: zipURL)
                    Alertinator.shared.alert(title: "Failed to compress file!", body: "The archive was created locally, but the remote Airlift write failed. Check the Airlift log.")
                }
            }
        }
    }

    private func uncompressFileAndSync() {
        if isAirliftRemote && !remoteMutationAllowed() {
            Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
            return
        }
        let archiveURL = file.fileURL
        let topLevel = archiveTopLevelNames(archiveURL)
        guard unzipFile(archiveURL) else {
            Haptic.shared.play(.heavy)
            Alertinator.shared.alert(title: "Failed to uncompress file!", body: Errors.checkLogs)
            return
        }

        guard isAirliftRemote,
              let remoteRoot = airliftRemotePath,
              let remoteParent = URL(fileURLWithPath: remoteRoot).deletingLastPathComponent().path as String? else {
            mgr.refreshFiles.toggle()
            return
        }

        Task {
            var allOK = true
            let localParent = archiveURL.deletingLastPathComponent()
            for name in topLevel {
                let localChild = localParent.appendingPathComponent(name)
                guard fm.fileExists(atPath: localChild.path) else { continue }
                let childRemote = URL(fileURLWithPath: remoteParent)
                    .appendingPathComponent(name)
                    .path
                let isDirectory = (try? localChild.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let ok: Bool
                if isDirectory {
                    ok = await AirliftBridge.shared.createRemoteDirectory(localURL: localChild, remotePath: childRemote)
                } else {
                    ok = await AirliftBridge.shared.writeBack(localURL: localChild, remotePath: childRemote)
                }
                if !ok { allOK = false }
            }
            await MainActor.run {
                if allOK {
                    mgr.refreshFiles.toggle()
                } else {
                    Alertinator.shared.alert(title: "Failed to write extracted files!", body: "The archive was extracted locally, but one or more remote Airlift writes failed. Check the Airlift log.")
                }
            }
        }
    }

    private func duplicateFileAndSync() {
        if isAirliftRemote && !remoteMutationAllowed() {
            Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
            return
        }
        let sourceURL = file.fileURL
        let targetURL = duplicateDestination(for: sourceURL)
        guard !fm.fileExists(atPath: targetURL.path) else {
            Alertinator.shared.alert(title: "Failed to duplicate file!", body: "A copy with that name already exists.")
            return
        }
        do {
            try fm.copyItem(at: sourceURL, to: targetURL)
        } catch {
            Alertinator.shared.alert(title: "Failed to duplicate file!", body: error.localizedDescription)
            return
        }

        guard isAirliftRemote, let remoteTarget = remoteSiblingPath(targetURL.lastPathComponent) else {
            mgr.refreshFiles.toggle()
            return
        }
        Task {
            let ok = await AirliftBridge.shared.writeBack(localURL: targetURL, remotePath: remoteTarget)
            await MainActor.run {
                if ok {
                    mgr.refreshFiles.toggle()
                } else {
                    try? fm.removeItem(at: targetURL)
                    Alertinator.shared.alert(title: "Failed to duplicate file!", body: "The remote Airlift write failed. Check the Airlift log.")
                }
            }
        }
    }

    private func deleteFileAndSync() {
        guard isAirliftRemote, let remotePath = airliftRemotePath else {
            do {
                try fm.removeItem(at: file.fileURL)
                mgr.refreshFiles.toggle()
            } catch {
                print("(fm) failed to delete file: \(error.localizedDescription)")
                Alertinator.shared.alert(title: "Failed to delete file!", body: Errors.checkLogs)
            }
            return
        }

        guard remoteMutationAllowed() else {
            Alertinator.shared.alert(title: "Airlift write unavailable", body: "Enable LocalDevVPN and make sure the pairing file is imported.")
            return
        }
        Task {
            let ok = await AirliftBridge.shared.removeRemotePath(remotePath)
            await MainActor.run {
                if ok {
                    do {
                        try fm.removeItem(at: file.fileURL)
                        mgr.refreshFiles.toggle()
                    } catch {
                        Alertinator.shared.alert(title: "Remote delete succeeded", body: "The snapshot could not be removed locally: \(error.localizedDescription)")
                    }
                } else {
                    Alertinator.shared.alert(title: "Failed to delete file!", body: "The remote Airlift delete failed. The local snapshot was kept unchanged. Check the Airlift log.")
                }
            }
        }
    }

    private func duplicateDestination(for url: URL) -> URL {
        if url.pathExtension.isEmpty {
            return url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent)_copy")
        }
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_copy.\(url.pathExtension)")
    }

    private func archiveTopLevelNames(_ url: URL) -> [String] {
        guard let archive = Archive(url: url, accessMode: .read) else { return [] }
        var names = Set<String>()
        for entry in archive {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            if let first = parts.first {
                names.insert(String(first))
            }
        }
        return names.sorted()
    }

}
