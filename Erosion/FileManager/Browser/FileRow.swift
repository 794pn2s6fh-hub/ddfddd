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
    @EnvironmentObject var mgr: ErosionManager
    @AppStorage("hideDates") var hideDates = false
    var file: FileItem
    var readOnly: Bool = false
    var airliftRemotePath: String? = nil
    var airliftRemoteRoot: String? = nil
    var airliftLocalRoot: String? = nil
    
    @State private var conformsText = false
    @State private var conformsPlist = false
    @State private var conformsZip = false
    
    @State private var showInfo = false
    @State private var showPlistViewer = false
    @State private var showTextViewer = false
    @State private var showExtendedPreview = false
    @State private var previewURL: URL?
    
    private var supportsExtendedPreview: Bool {
        ["dylib", "bin", "so", "o", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac", "pdf"].contains(file.fileURL.pathExtension.lowercased())
    }

    private var isBinaryPreview: Bool {
        ["dylib", "bin", "so", "o"].contains(file.fileURL.pathExtension.lowercased())
    }

    private var isAirliftRemote: Bool {
        airliftRemotePath != nil && airliftRemoteRoot != nil && airliftLocalRoot != nil
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

    var body: some View {
        Group {
            if file.type == .file {
                Button {
                    if conformsZip && !readOnly {
                        uncompressFileAndSync()
                    } else {
                        if isBinaryPreview || supportsExtendedPreview {
                            showExtendedPreview = true
                        } else if conformsPlist {
                            showPlistViewer.toggle()
                        } else if conformsText {
                            showTextViewer.toggle()
                        } else {
                            previewURL = file.fileURL
                        }
                    }
                } label: {
                    HStack(spacing: isSolariumUI() ? 12 : 10) {
                        Image(systemName: "doc")
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
                        
                        if file.type == .file {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        
                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, !hideDates && !file.modifiedDateStr.isEmpty && file.type == .file && !isSolariumUI() ? 1 : 0)
                }
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
                        
                        Button {
                            showInfo.toggle()
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(Color(.label))
        .onAppear {
            conformsText = conformsToTextViewer(file.fileURL)
            conformsPlist = conformsToPlistViewer(file.fileURL)
            if file.uttype.conforms(to: .zip) {
                conformsZip = true
            }
        }
        .sheet(isPresented: $showInfo) {
            InfoViewer(file, pathOverride: airliftRemotePath)
        }
        .sheet(isPresented: $showPlistViewer) {
            PlistViewer(file.fileURL, remotePath: airliftRemotePath)
        }
        .sheet(isPresented: $showTextViewer) {
            TextViewer(file.fileURL, remotePath: airliftRemotePath)
        }
        .sheet(isPresented: $showExtendedPreview) {
            NavigationStack {
                FilePreviewView(url: file.fileURL, remotePath: airliftRemotePath, remoteWritable: !readOnly && isAirliftRemote)
            }
        }
        .quickLookPreview($previewURL)
        // MARK: cell actions
        .contextMenu {
            if conformsText || conformsPlist || supportsExtendedPreview {
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
                    if conformsPlist {
                        Button {
                            showPlistViewer.toggle()
                        } label: {
                            Label("Plist Viewer", systemImage: "tablecells")
                        }
                    }
                    
                    if conformsText {
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
                        previewURL = file.fileURL
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
                if conformsZip {
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
                let res = copyFileToClipboard(file.fileURL)
                if !res {
                    Alertinator.shared.alert(title: "Failed to copy file!", body: Errors.checkLogs)
                }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            
            Button {
                if let url = makeTemp(file.fileURL) {
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
