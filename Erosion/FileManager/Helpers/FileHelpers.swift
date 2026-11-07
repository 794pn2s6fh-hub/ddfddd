//
//  FileHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import SwiftUI
import ZIPFoundation
import UniformTypeIdentifiers

extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws {
        if !self.fileExists(atPath: url.path) {
            try self.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

func getFileDict(_ url: URL) -> [String : Any]? {
    if let data = try? Data(contentsOf: url),
       let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String : Any] {
        return dict
    }
    
    return nil
}

func getFileText(_ url: URL) -> String {
    do {
        let data = try Data(contentsOf: url)
        
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        
        return String(decoding: data, as: UTF8.self)
    } catch {
        print("(fm) failed to get text! path: \(error.localizedDescription)")
        return ""
    }
}

func makeTemp(_ fileURL: URL) -> URL? {
    do {
        let neededAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if neededAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let tempURL = URL.temporaryDirectory.appendingPathComponent("\(fileURL.lastPathComponent)")
        if fm.fileExists(atPath: tempURL.path) {
            try fm.removeItem(at: tempURL)
        }
        try fm.copyItem(at: fileURL, to: tempURL)
        return tempURL
    } catch {
        print("(fm) failed to make temp: \(error.localizedDescription)")
    }
    return nil
}

func generateNavPath(path: String) -> String {
    if !path.contains("/") || path.isEmpty {
        return ""
    }
    
    let file = getFileItem(at: URL(fileURLWithPath: path))
    
    if file.type == .folder || file.type == .symlink {
        return path
    }
    
    if file.type == .file {
        let navPath = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return navPath
    }
    return ""
}

func renameFile(_ url: URL, to newName: String) -> Bool {
    do {
        let data = try Data(contentsOf: url)
        try fm.removeItem(at: url)
        let targetURL = url.deletingLastPathComponent().appendingPathComponent(newName)
        try data.write(to: targetURL)
        return true
    } catch {
        print("(fm) failed to rename file: \(error.localizedDescription)")
    }
    return false
}


/// Copies the readable portion of a directory tree into a temporary destination.
/// Unavailable children are omitted while readable siblings remain available to ZIP.
private func copyDirectoryContentsBestEffort(at sourceURL: URL, to destinationURL: URL, depth: Int = 0) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    guard depth < 64 else { return }

    let children: [URL]
    do {
        children = try manager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
    } catch {
        return
    }

    for child in children {
        let destination = destinationURL.appendingPathComponent(child.lastPathComponent)
        do {
            let attributes = try manager.attributesOfItem(atPath: child.path)
            let itemType = attributes[.type] as? FileAttributeType

            if itemType == .typeSymbolicLink {
                let linkTarget = try manager.destinationOfSymbolicLink(atPath: child.path)
                try manager.createSymbolicLink(atPath: destination.path, withDestinationPath: linkTarget)
            } else if itemType == .typeDirectory {
                try copyDirectoryContentsBestEffort(at: child, to: destination, depth: depth + 1)
            } else {
                try manager.copyItem(at: child, to: destination)
            }
        } catch {
            // Continue with the remaining siblings.
            continue
        }
    }
}

/// Creates a ZIP copy of a read-only item inside the File Browser Workspace.
/// The source is staged inside Workspace so the original directory is never modified.
func zipItemToWorkspace(at sourceURL: URL, preferredName: String? = nil, data: Data? = nil, isDirectory: Bool = false) throws -> URL {
    let manager = FileManager.default
    let applicationSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL.documentsDirectory.appendingPathComponent("Application Support", isDirectory: true)
    let workspace = applicationSupport.appendingPathComponent("Workspace", isDirectory: true)
    try manager.createDirectory(at: workspace, withIntermediateDirectories: true)

    let requestedName = preferredName ?? sourceURL.lastPathComponent
    let itemName = URL(fileURLWithPath: requestedName).lastPathComponent
    guard !itemName.isEmpty, itemName != ".", itemName != ".." else {
        throw NSError(domain: "ErosionWorkspaceZIP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid archive name."])
    }
    let destinationURL = workspace.appendingPathComponent(itemName + ".zip")
    guard !manager.fileExists(atPath: destinationURL.path) else {
        throw NSError(domain: "ErosionWorkspaceZIP", code: 2, userInfo: [NSLocalizedDescriptionKey: "An archive named \(itemName).zip already exists in Workspace."])
    }

    let staging = workspace.appendingPathComponent(".zip-staging-\(UUID().uuidString)", isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: staging) }

    let stagedItem = staging.appendingPathComponent(itemName, isDirectory: isDirectory)
    if let data {
        try data.write(to: stagedItem, options: .atomic)
    } else if isDirectory {
        try copyDirectoryContentsBestEffort(at: sourceURL, to: stagedItem)
    } else {
        try manager.copyItem(at: sourceURL, to: stagedItem)
    }

    let stagedArchive = staging.appendingPathComponent(itemName + ".zip")
    try manager.zipItem(at: stagedItem, to: stagedArchive, shouldKeepParent: true)
    try manager.moveItem(at: stagedArchive, to: destinationURL)
    return destinationURL
}

func zipFile(_ url: URL, isDirectory directoryHint: Bool? = nil) -> Bool {
    let manager = FileManager.default
    let zipDest = url
        .deletingLastPathComponent()
        .appendingPathComponent(url.lastPathComponent + ".zip")

    do {
        var detectedDirectory: ObjCBool = false
        let shouldStageDirectory = directoryHint
            ?? (manager.fileExists(atPath: url.path, isDirectory: &detectedDirectory) && detectedDirectory.boolValue)
        if shouldStageDirectory {
            let stagingRoot = manager.temporaryDirectory
                .appendingPathComponent("ErosionZIP-\(UUID().uuidString)", isDirectory: true)
            defer { try? manager.removeItem(at: stagingRoot) }

            let stagedDirectory = stagingRoot.appendingPathComponent(url.lastPathComponent, isDirectory: true)
            try copyDirectoryContentsBestEffort(at: url, to: stagedDirectory)
            try manager.zipItem(at: stagedDirectory, to: zipDest, shouldKeepParent: true)
        } else {
            try manager.zipItem(at: url, to: zipDest, shouldKeepParent: true)
        }
        return true
    } catch {
        print("(fm) failed to zip file: \(error.localizedDescription)")
    }
    return false
}

func unzipFile(_ url: URL) -> Bool {
    do {
        let unzipDest = url.deletingLastPathComponent()
        try fm.createDirectory(at: unzipDest, withIntermediateDirectories: true)
        try fm.unzipItem(at: url, to: unzipDest)
        return true
    } catch {
        print("(fm) failed to uncompress file: \(error.localizedDescription)")
    }
    return false
}

func duplicateFile(_ url: URL) -> Bool {
    do {
        let targetURL = {
            if url.pathExtension == "" {
                return url
                    .deletingLastPathComponent()
                    .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_copy")
            }
            return url
                .deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)_copy.\(url.pathExtension)")
        }()
        let data = try Data(contentsOf: url)
        try data.write(to: targetURL)
        return true
    } catch {
        print("(fm) failed to duplicate file: \(error.localizedDescription)")
    }
    return false
}

func copyFileToClipboard(_ url: URL) -> Bool {
    do {
        guard let tempURL = makeTemp(url) else {
            throw "failed to make temp!"
        }
        let data = try Data(contentsOf: tempURL)
        let utType = UTType(filenameExtension: tempURL.pathExtension) ?? .data
        
        UIPasteboard.general.setData(data, forPasteboardType: utType.identifier)
        return true
    } catch {
        print("(fm) failed to copy file: \(error.localizedDescription)")
    }
    return false
}

/// Copies a virtual file snapshot directly to the pasteboard without creating a local file.
func copyDataToClipboard(_ data: Data, fileName: String) -> Bool {
    let fileExtension = URL(fileURLWithPath: fileName).pathExtension
    let utType = UTType(filenameExtension: fileExtension) ?? .data
    UIPasteboard.general.setData(data, forPasteboardType: utType.identifier)
    return true
}

func conformsToPlistViewer(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url), !data.isEmpty,
          let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
          object is [String: Any] else {
        return false
    }
    return true
}

func conformsToTextViewer(_ url: URL) -> Bool {
    do {
        let _ = try String(contentsOf: url, encoding: .utf8)
        return true
    } catch {
        return false
    }
}
