//
//  FileInfoSheet.swift
//  AccessiblePlus
//
//  Created by lunginspector on 5/20/26.
//

import SwiftUI

import UniformTypeIdentifiers

struct InfoViewer: View {
    @Environment(\.dismiss) var dismiss
    var file: FileItem
    var pathOverride: String? = nil
    @State private var folderSize: Int64?
    @State private var virtualMetadata: FileItem?

    private var displayFile: FileItem { virtualMetadata ?? file }
    
    init(_ file: FileItem, pathOverride: String? = nil) {
        self.file = file
        self.pathOverride = pathOverride
    }
    
    private var hidesSystemLibraryFolderSize: Bool {
        let path = displayFile.fileURL.standardizedFileURL.path
        return path == "/System/Library" || path.hasPrefix("/System/Library/")
    }

    /// Bundle/Application rows are metadata-only .app path labels. Their bundle
    /// trees must never be recursively walked from Info because navigation is blocked.
    private var symlinkTargetIsDirectory: Bool {
        displayFile.type == .symlink && FolderContentSizeReader.isDirectory(at: displayFile.destURL)
    }

    private var showsDirectorySize: Bool {
        if displayFile.type == .symlink {
            return symlinkTargetIsDirectory
        }
        return displayFile.type == .folder
            && !hidesSystemLibraryFolderSize
            && !hidesBundleContainerFolderSize
            && !hidesCoreServicesAppBundleFolderSize
    }

    private var hidesCoreServicesAppBundleFolderSize: Bool {
        let path = displayFile.fileURL.standardizedFileURL.path
        let root = "/System/Library/CoreServices/"
        guard path.hasPrefix(root) else { return false }
        let components = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        return components.count == 1 && String(components[0]).lowercased().hasSuffix(".app")
    }

    private var hidesBundleContainerFolderSize: Bool {
        let path = displayFile.fileURL.standardizedFileURL.path
        let root = FSPaths.appBundles + "/"
        guard path.hasPrefix(root) else { return false }
        let components = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              UUID(uuidString: String(components[0])) != nil else { return false }
        return String(components[1]).lowercased().hasSuffix(".app")
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    StringInfoCell(displayFile.name, label: "Name")
                    StringInfoCell(pathOverride ?? displayFile.fileURL.path, label: "Path")
                    if displayFile.type == .symlink {
                        StringInfoCell(displayFile.destURL.path, label: "Destination Path")
                    }
                    if displayFile.type == .file {
                        // Keep the existing file-size row unchanged.
                        StringInfoCell("\(ByteCountFormatter.string(fromByteCount: Int64(displayFile.size), countStyle: .file))", label: "Size")
                    } else if showsDirectorySize, let folderSize {
                        StringInfoCell(ByteCountFormatter.string(fromByteCount: folderSize, countStyle: .file), label: "Size")
                    }
                }
                
                Section {
                    StringInfoCell(displayFile.uttype.identifier, label: "UTType")
                    StringInfoCell(displayFile.creationDateStr, label: "Creation Date")
                    StringInfoCell(displayFile.modifiedDateStr, label: "Last Modified")
                    BoolInfoCell(displayFile.type == .symlink, label: "Symlink")
                } header: {
                    HeaderLabel("File", symbol: "doc")
                }
                
                Section {
                    StringInfoCell(displayFile.posixPerms, label: "POSIX Permissions")
                    StringInfoCell(displayFile.owner, label: "Owner")
                    StringInfoCell(displayFile.group, label: "Group")
                    BoolInfoCell(displayFile.readable, label: "Readable")
                    BoolInfoCell(displayFile.writable, label: "Writable")
                    BoolInfoCell(displayFile.executable, label: "Executable")
                } header: {
                    HeaderLabel("Permissions", symbol: "shield")
                }
            }
            .navigationTitle("\(displayFile.type.rawValue.capitalized) Info")
            .navigationBarTitleDisplayMode(.inline)
            .listStyle(.insetGrouped)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        ToolbarLabel("Close", symbol: "xmark")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task(id: file.fileURL.path + "|" + file.destURL.path) {
            if CoreMediaVirtualSystemPathReader.containsVirtualPath(file.fileURL) {
                let virtualPath = file.fileURL.path
                let infoData = await Task.detached(priority: .utility) {
                    CoreMediaVirtualSystemPathReader.infoData(atPath: virtualPath)
                }.value
                if let refreshedMetadata = infoData.item {
                    virtualMetadata = refreshedMetadata
                }
                if showsDirectorySize {
                    folderSize = infoData.directorySize
                }
                return
            }

            guard showsDirectorySize else { return }
            let sizeURL = displayFile.type == .symlink ? displayFile.destURL : displayFile.fileURL
            do {
                let calculatedSize = try await Task.detached(priority: .utility) {
                    try FolderContentSizeReader.calculate(at: sizeURL)
                }.value
                folderSize = calculatedSize
            } catch {
                // A partial total would be misleading. Hide Size entirely when
                // any child needed for the calculation cannot be read.
                folderSize = nil
            }
        }
    }
    
    private struct StringInfoCell: View {
        var string: String
        var label: String
        
        init(_ string: String, label: String) {
            self.string = string
            self.label = label
        }
        
        var body: some View {
            HStack {
                Text(label)
                Spacer()
                Text(string.isEmpty ? "—" : string)
                    .foregroundStyle(.secondary)
            }
        .contextMenu {
                Button {
                    UIPasteboard.general.string = string
                } label: {
                    Label("Copy Value", systemImage: "doc.on.doc")
                }
            }
        }
    }
    
    private struct BoolInfoCell: View {
        var bool: Bool?
        var label: String
        
        init(_ bool: Bool?, label: String) {
            self.bool = bool
            self.label = label
        }
        
        var body: some View {
            HStack {
                Text(label)
                Spacer()
                Image(systemName: bool.map { $0 ? "checkmark" : "xmark" } ?? "minus")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
