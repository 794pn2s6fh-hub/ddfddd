import Foundation
import UIKit
import Combine

private func airliftWalletSyslogCallback(_ ctx: UnsafeMutableRawPointer?, _ line: UnsafePointer<CChar>?) {
    guard let line else { return }
    let text = String(cString: line)
    Task { @MainActor in
        WalletCardSkinManager.shared?.processSyslogLine(text)
    }
}

@MainActor
final class WalletCardSkinManager: ObservableObject {
    static weak var shared: WalletCardSkinManager?

    @Published private(set) var cardIDs: [String] = []
    @Published var selectedCardIDs: Set<String> = []
    @Published var imageData: Data?
    @Published private(set) var isScanning = false
    @Published private(set) var scanStatus = ""
    @Published private(set) var flashRunning = false
    @Published private(set) var flashLog: [String] = []
    @Published var manualCardID = ""

    private static let cardRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,64})(?:\\.pkpass|\\.cache|\\.pkcache|/|\\s|\"|'|\\)|,|$)"),
        try! NSRegularExpression(pattern: "/([-A-Za-z0-9_+=]{20,64})\\.(?:pkpass|cache|pkcache)"),
        try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])")
    ]

    init() {
        Self.shared = self
    }

    var canApply: Bool {
        !flashRunning && !selectedCardIDs.isEmpty && imageData != nil && PairingController.pairingFilePathExists()
    }

    func setImageData(_ data: Data) {
        guard !data.isEmpty, UIImage(data: data) != nil else { return }
        imageData = data
        appendLog("Loaded card artwork.")
    }

    func clearImage() {
        imageData = nil
    }

    func toggleSelected(_ id: String) {
        if selectedCardIDs.contains(id) {
            selectedCardIDs.remove(id)
        } else {
            selectedCardIDs.insert(id)
        }
    }

    func selectAll() {
        selectedCardIDs = Set(cardIDs)
    }

    func deselectAll() {
        selectedCardIDs.removeAll()
    }

    func addManualCard() {
        guard let clean = Self.cleanCardID(manualCardID) else {
            appendLog("❌ Invalid card identifier")
            return
        }
        if !cardIDs.contains(clean) {
            cardIDs.append(clean)
        }
        selectedCardIDs.insert(clean)
        manualCardID = ""
        appendLog("Added card: \(clean.prefix(12))…")
    }

    func startScanning() {
        guard !isScanning else { return }
        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            appendLog("❌ No pairing file")
            return
        }

        isScanning = true
        scanStatus = "Open Apple Pay and tap the card…"
        appendLog("Started Wallet card scanner…")

        let thread = Thread {
            var outError: UnsafeMutablePointer<CChar>? = nil
            let rc = pairingPath.withCString { pairC in
                al_syslog_stream_start(pairC, airliftWalletSyslogCallback, nil, &outError)
            }
            let err = outError.flatMap { p -> String? in
                let s = String(validatingUTF8: p)
                al_string_free(p)
                return s
            }
            Task { @MainActor in
                guard let manager = WalletCardSkinManager.shared else { return }
                manager.isScanning = false
                if rc != 0 {
                    manager.scanStatus = "Scanner stopped: \(err ?? "rc=\(rc)")"
                    manager.appendLog("❌ Scanner error: \(err ?? "rc=\(rc)")")
                } else {
                    manager.scanStatus = "Scanning stopped. Cards: \(manager.cardIDs.count)"
                }
            }
        }
        thread.name = "Erosion.WalletCardScanner"
        thread.stackSize = 4 * 1024 * 1024
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopScanning() {
        al_syslog_stream_stop()
        isScanning = false
        scanStatus = "Scanning stopped. Cards: \(cardIDs.count)"
    }

    func processSyslogLine(_ line: String) {
        let lower = line.lowercased()
        guard lower.contains("wallet") || lower.contains("passbook") || lower.contains("passkit") ||
              lower.contains("pdcardfilemanager") || lower.contains("pdpasslibrary") || lower.contains("/cards/") else { return }

        for regex in Self.cardRegexes {
            for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: line),
                      let clean = Self.cleanCardID(String(line[range])) else { continue }
                if !cardIDs.contains(clean) {
                    cardIDs.append(clean)
                    selectedCardIDs.insert(clean)
                    scanStatus = "Found card: \(clean.prefix(12))…"
                    appendLog("Found card: \(clean)")
                }
            }
        }
    }

    func applySelectedCards() {
        guard canApply, let imageData else { return }
        let ids = Array(selectedCardIDs)
        let pairingPath = PairingController.pairingFilePath()
        flashRunning = true
        flashLog.removeAll()
        appendLog("Applying Apple Wallet artwork to \(ids.count) card(s)…")

        DispatchQueue.global(qos: .userInitiated).async {
            guard let image = UIImage(data: imageData),
                  let skins = Self.prepareAllCardSkins(from: image),
                  !skins.isEmpty else {
                Task { @MainActor in
                    WalletCardSkinManager.shared?.flashRunning = false
                    WalletCardSkinManager.shared?.appendFlashLog("❌ Failed to prepare artwork")
                }
                return
            }

            var success = 0
            for (index, cardID) in ids.enumerated() {
                let stage = FileManager.default.temporaryDirectory
                    .appendingPathComponent("erosion_wallet_\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                for (name, data) in skins {
                    try? data.write(to: stage.appendingPathComponent(name))
                }

                let target = "/var/mobile/Library/Passes/Cards/\(cardID).pkpass"
                Task { @MainActor in
                    WalletCardSkinManager.shared?.appendFlashLog("[\(index + 1)/\(ids.count)] Writing \(cardID.prefix(12))…")
                }
                let ok = Self.writeDirectory(pairingPath: pairingPath, source: stage.path, target: target)
                try? FileManager.default.removeItem(at: stage)

                if ok {
                    success += 1
                    Task { @MainActor in WalletCardSkinManager.shared?.appendFlashLog("  ✅ Artwork written") }
                    Self.invalidateCache(pairingPath: pairingPath, cardID: cardID)
                    Task { @MainActor in WalletCardSkinManager.shared?.appendFlashLog("  ✅ Wallet cache invalidated") }
                } else {
                    Task { @MainActor in WalletCardSkinManager.shared?.appendFlashLog("  ❌ Failed to write card") }
                }
            }

            Task { @MainActor in
                WalletCardSkinManager.shared?.flashRunning = false
                WalletCardSkinManager.shared?.appendFlashLog("Finished: \(success)/\(ids.count) card(s)")
            }
        }
    }

    func appendLog(_ line: String) {
        flashLog.append(line)
        if flashLog.count > 200 { flashLog.removeFirst(flashLog.count - 160) }
    }

    private func appendFlashLog(_ line: String) {
        flashLog.append(line)
        if flashLog.count > 200 { flashLog.removeFirst(flashLog.count - 160) }
    }

    private static func writeDirectory(pairingPath: String, source: String, target: String) -> Bool {
        var outError: UnsafeMutablePointer<CChar>? = nil
        let rc = pairingPath.withCString { p in
            source.withCString { s in
                target.withCString { t in
                    al_exploit_write_dir(p, s, t, nil, nil, &outError)
                }
            }
        }
        if let outError {
            al_string_free(outError)
        }
        return rc == 0
    }

    private static func invalidateCache(pairingPath: String, cardID: String) {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion_wallet_inv_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
            try? Data("corrupted".utf8).write(to: stage.appendingPathComponent(leaf))
        }
        for ext in [".cache", ".pkcache"] {
            _ = writeDirectory(
                pairingPath: pairingPath,
                source: stage.path,
                target: "/var/mobile/Library/Passes/Cards/\(cardID)\(ext)"
            )
        }
        try? FileManager.default.removeItem(at: stage)
    }

    private static func prepareAllCardSkins(from image: UIImage) -> [String: Data]? {
        let normalized = normalizeAndDownsample(image, maxDimension: 2560)
        var skins: [String: Data] = [:]
        if let data3x = resizeImage(normalized, targetSize: CGSize(width: 1536, height: 969)) {
            skins["cardBackgroundCombined@3x.png"] = data3x
            skins["diffuse@3x.png"] = data3x
            skins["background@3x.png"] = data3x
            skins["strip@3x.png"] = data3x
        }
        if let data2x = resizeImage(normalized, targetSize: CGSize(width: 1024, height: 646)) {
            skins["cardBackgroundCombined@2x.png"] = data2x
            skins["diffuse@2x.png"] = data2x
            skins["background@2x.png"] = data2x
            skins["strip@2x.png"] = data2x
        }
        let rect = CGRect(origin: .zero, size: CGSize(width: 1536, height: 969))
        let renderer = UIGraphicsPDFRenderer(bounds: rect)
        let pdf = renderer.pdfData { ctx in
            ctx.beginPage()
            normalized.draw(in: rect)
        }
        skins["cardBackgroundCombined.pdf"] = pdf
        skins["background.pdf"] = pdf
        skins["strip.pdf"] = pdf
        return skins
    }

    private static func normalizeAndDownsample(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let target = CGSize(width: max(1, floor(size.width * scale)), height: max(1, floor(size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func resizeImage(_ image: UIImage, targetSize: CGSize) -> Data? {
        let scale = max(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (targetSize.width - scaled.width) / 2, y: (targetSize.height - scaled.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: scaled))
        }.pngData()
    }

    private static func cleanCardID(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}"))
        if value.contains("/") { value = (value as NSString).lastPathComponent }
        for ext in [".pkpass", ".cache", ".pkcache"] where value.hasSuffix(ext) {
            value = String(value.dropLast(ext.count))
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}. "))
        guard value.count >= 20 && value.count <= 64 && !value.contains("/") else { return nil }
        if value.count == 36 && value.filter({ $0 == "-" }).count == 4 { return nil }
        return value
    }
}

private extension PairingController {
    static func pairingFilePathExists() -> Bool {
        let path = PairingController.pairingFilePath()
        return FileManager.default.fileExists(atPath: path)
    }
}
