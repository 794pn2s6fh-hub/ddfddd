//
//  FSHandlers.swift
//  Erosion
//
//  Created by lunginspector on 8/19/26.
//

import Foundation
import UIKit
import Darwin

let fsHandlers = FSHandlers()

class FSHandlers {
    func getDirPaths(_ path: String, maxInode: Int64 = 10000000) -> [String] {
        var array = [""]
        path.withCString { path in
            guard let res = bad_query_list(UnsafeMutablePointer(mutating: path), maxInode) else {
                return
            }
            defer { free(res) }
            
            let string = String(cString: res)
            array = string.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        return array
    }
    
    func getContainerPath(at containerURL: URL = FSURL.appContainers, forMatch match: String, hashOnly: Bool = false) -> String {
        let containers = getDirPaths(containerURL.path)
        for path in containers {
            let url = URL(fileURLWithPath: path)
            if let appName = folderLabel(url: url) {
                if appName == match {
                    if hashOnly {
                        return url.lastPathComponent
                    }
                    return url.path
                }
            }
        }
        print("(fs) failed to get container for \(match)! containers: \(containerURL.path)")
        return ""
    }
    
    /// Original Erosion Worse Query path-discovery flow, isolated from the
    /// BadQuery-backed helpers used elsewhere in the modified file browser.
    func getContainerPathWithWorseQuery(
        at containerURL: URL = FSURL.appContainers,
        forMatch match: String,
        hashOnly: Bool = false
    ) -> String {
        let baselineURL = fm.temporaryDirectory.appendingPathComponent(".baseline_\(UUID().uuidString)")
        var baselineInfo = stat()

        do {
            try "thxforcequit".write(to: baselineURL, atomically: true, encoding: .utf8)
            guard stat(baselineURL.path, &baselineInfo) == 0 else {
                try? fm.removeItem(at: baselineURL)
                print("(fs) failed to get baseline inode for Worse Query path discovery")
                return ""
            }
            try fm.removeItem(at: baselineURL)
        } catch {
            try? fm.removeItem(at: baselineURL)
            print("(fs) failed to create Worse Query path baseline: \(error.localizedDescription)")
            return ""
        }

        let containers = pathleak(containerURL.path, baselineInfo.st_ino) ?? []
        for path in containers {
            let url = URL(fileURLWithPath: path)
            guard worseQueryContainerIdentifier(url) == match else { continue }
            return hashOnly ? url.lastPathComponent : url.path
        }

        print("(fs) failed to get container for \(match) via Worse Query; root: \(containerURL.path)")
        return ""
    }

    private func worseQueryContainerIdentifier(_ url: URL) -> String? {
        let access = wq.grantAccess(path: url.path)
        guard access.0, access.1 >= 0 else { return nil }
        defer { worse_query_release(access.1) }

        var buffer = [CChar](repeating: 0, count: 512)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            getxattr(
                url.path,
                "com.apple.containermanager.identifier",
                pointer.baseAddress,
                511,
                0,
                0
            )
        }
        guard length > 0 else { return nil }
        let identifier = String(cString: buffer)
        return identifier.isEmpty ? nil : identifier
    }

    func openInFilesApp(_ fileURL: URL) {
        guard var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else { return }
        components.scheme = "shareddocuments"
        guard let filesAppURL = components.url else { return }
        UIApplication.shared.open(filesAppURL)
    }
}
