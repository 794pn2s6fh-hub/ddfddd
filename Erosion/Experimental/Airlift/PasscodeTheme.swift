import Foundation
import UIKit
import AirliftFFI

struct ErosionPasscodeTheme: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let keys: [String: UIImage]
    let rawData: [String: Data]
    let fileCount: Int
}

enum ErosionPasscodeThemeReader {
    static func inspect(url: URL) -> ErosionPasscodeTheme? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_passthm_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rc = url.path.withCString { arcC in
            tempDir.path.withCString { dstC in
                al_passthm_extract(arcC, dstC)
            }
        }
        guard rc == 0 else { return nil }

        let files = FileManager.default.subpaths(atPath: tempDir.path) ?? []
        var keys: [String: UIImage] = [:]
        var raw: [String: Data] = [:]
        var count = 0

        for file in files {
            guard !file.hasPrefix("."), !file.contains("__MACOSX") else { continue }
            let lower = file.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") else { continue }
            count += 1

            let filename = (file as NSString).lastPathComponent
            guard let digit = extractDigit(filename), keys[digit] == nil else { continue }

            let path = tempDir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: path), let image = UIImage(data: data) else { continue }
            raw[digit] = data
            keys[digit] = image
        }

        guard !keys.isEmpty else { return nil }
        return ErosionPasscodeTheme(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            keys: keys,
            rawData: raw,
            fileCount: count
        )
    }

    private static func extractDigit(_ filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
            .replacingOccurrences(of: "--white", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "-white", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "@3x", with: "")
            .replacingOccurrences(of: "@2x", with: "")

        if let regex = try? NSRegularExpression(
            pattern: #"(?:^[a-zA-Z]+-)?([0-9])"#,
            options: .caseInsensitive
        ) {
            let ns = stem as NSString
            if let match = regex.firstMatch(in: stem, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                let value = ns.substring(with: match.range(at: 1))
                if value.count == 1 { return value }
            }
        }

        for ch in stem where "0123456789".contains(ch) {
            return String(ch)
        }
        return nil
    }
}
