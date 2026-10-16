import Foundation
import Combine

/// Drives the RPPairing host: requests Local Network, keeps the app alive while
/// the user approves the PIN in Settings, advertises the service over Bonjour,
/// and runs `al_pairing_run_host` off the main thread.
final class PairingController: ObservableObject, @unchecked Sendable {

    static let shared = PairingController()

    private let hostName = "Erosion"
    private let hostModel = "Mac17,7"   // device sees a Mac-like pairing host
    private let bindAddress = "0.0.0.0"

    private var netService: NetService?
    private let localNetwork = LocalNetworkAuthorization()
    private let keepAlive = KeepAlive()

    private(set) var running = false
    var pairingStatus: String = "idle"
    var pairingPIN: String? = nil

    /// Path to the pairing file that was actively found or created.
    nonisolated(unsafe) static var customPairingFilePath: String? = nil

    /// Persisted altIRK keeps the host identity stable across pairings so a
    /// device that has already paired recognises this host.
    private static let altIRKKey = "erosionPairingHostAltIRK"
    private static var storedAltIRK: String {
        get { UserDefaults.standard.string(forKey: altIRKKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: altIRKKey) }
    }

    private var pairContinuation: CheckedContinuation<String, Error>?

    // MARK: - Public API

    enum PairingError: LocalizedError {
        case busy
        case localNetworkDenied
        case zeroBytes
        case invalidPairingFile(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "Pairing is already in progress."
            case .localNetworkDenied: return "Local Network permission is off. Enable it in Settings › Erosion › Local Network."
            case .zeroBytes: return "Pairing produced an empty file. Approve the pairing request, then try again."
            case let .invalidPairingFile(msg): return "Invalid pairing file: \(msg)"
            case let .failed(msg): return msg
            }
        }
    }

    /// Imports an RPPairing plist without replacing the current pairing unless
    /// the file passes structural validation. This intentionally accepts both
    /// XML and binary plist containers.
    @discardableResult
    static func importPairingFile(from sourceURL: URL) throws -> String {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw PairingError.invalidPairingFile("could not read the file")
        }

        guard !data.isEmpty else {
            throw PairingError.invalidPairingFile("file is empty")
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ), let dict = plist as? [String: Any] else {
            throw PairingError.invalidPairingFile("not a valid plist")
        }

        // RPPairing records used by Airlift contain these three core fields.
        // Some merged pairing files additionally contain the classic lockdown
        // record; that is fine as long as the RPPairing half is present.
        guard let publicKey = dict["public_key"] as? Data, publicKey.count == 32 else {
            throw PairingError.invalidPairingFile("missing/invalid public_key (expected 32 bytes)")
        }
        guard let privateKey = dict["private_key"] as? Data, privateKey.count == 32 else {
            throw PairingError.invalidPairingFile("missing/invalid private_key (expected 32 bytes)")
        }
        guard let identifier = dict["identifier"] as? String, UUID(uuidString: identifier) != nil else {
            throw PairingError.invalidPairingFile("missing/invalid identifier")
        }

        if let altIRK = dict["alt_irk"] as? Data, altIRK.count != 16 {
            throw PairingError.invalidPairingFile("invalid alt_irk (expected 16 bytes)")
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let canonicalURL = docs.appendingPathComponent("erosion_pairing.plist")
        do {
            try data.write(to: canonicalURL, options: .atomic)
        } catch {
            throw PairingError.invalidPairingFile("could not save the pairing file")
        }

        customPairingFilePath = canonicalURL.path
        return canonicalURL.path
    }

    /// Ensures the given pairing file is mirrored to canonical erosion_pairing.plist and erosion_pairing.plist.
    @discardableResult
    static func syncCanonicalPairingFile(from sourcePath: String) -> String {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let canonicalURL = dir.appendingPathComponent("erosion_pairing.plist")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sourcePath)), !data.isEmpty {
            if sourcePath != canonicalURL.path {
                try? data.write(to: canonicalURL, options: .atomic)
                try? fm.removeItem(atPath: sourcePath)
            }
        }
        if let files = try? fm.contentsOfDirectory(atPath: dir.path) {
            for f in files {
                guard f.hasSuffix(".plist") || f.hasSuffix(".mobilepairing") || f.hasSuffix(".mobilepair") else { continue }
                let path = dir.appendingPathComponent(f).path
                if path == canonicalURL.path { continue }
                try? fm.removeItem(atPath: path)
            }
        }
        customPairingFilePath = canonicalURL.path
        return canonicalURL.path
    }

    /// Path where the pairing file is written or read from.
    /// Checks for canonical erosion_pairing.plist, custom path, or any plist in Documents,
    /// automatically adopting and standardizing it.
    static func pairingFilePath() -> String {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let canonical = dir.appendingPathComponent("erosion_pairing.plist").path
        if fm.fileExists(atPath: canonical) {
            let size = (try? fm.attributesOfItem(atPath: canonical)[.size] as? Int) ?? 0
            if size > 0 { return canonical }
        }
        if let custom = customPairingFilePath, fm.fileExists(atPath: custom) {
            let size = (try? fm.attributesOfItem(atPath: custom)[.size] as? Int) ?? 0
            if size > 0 { return syncCanonicalPairingFile(from: custom) }
        }
        return canonical
    }

    /// Start the host and resolve with the pairing-file path, or throw.
    func startAndWait() async throws -> String {
        // If already running, cancel previous to allow clean restart
        if running {
            softCancel()
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await withCheckedThrowingContinuation { cont in
            pairContinuation = cont
            start()
        }
    }

    func softCancel() {
        stopAdvertising()
        keepAlive.stopAll()
        running = false
        pairingPIN = nil
        pairingStatus = "Cancelled"
        resolve(.failure(CancellationError()))
    }

    private func resolve(_ result: Result<String, Error>) {
        guard let cont = pairContinuation else { return }
        pairContinuation = nil
        cont.resume(with: result)
    }

    func start() {
        stopAdvertising()
        keepAlive.stopAll()
        running = true
        pairingPIN = nil
        pairingStatus = "Starting local host…"

        Task {
            _ = await localNetwork.request()
            guard running else { return }

            keepAlive.startAudio()
            pairingStatus = "Broadcasting… open Settings to pair"
            runHost()
        }
    }

    // MARK: - Private

    private func runHost() {
        let bind = bindAddress
        let name = hostName
        let model = hostModel
        let outPath = Self.pairingFilePath()
        let altIRK = Self.storedAltIRK
        let ctx = UnsafeMutableRawPointer(
            Unmanaged.passRetained(self).toOpaque()
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var result = ALPairResult()
            let rc = bind.withCString { bindC in
                name.withCString { nameC in
                    model.withCString { modelC in
                        outPath.withCString { outC in
                            altIRK.withCString { irkC in
                                al_pairing_run_host(
                                    bindC, 0, nameC, modelC, outC, irkC,
                                    pairReadyCallback, pairPinCallback, ctx, &result)
                            }
                        }
                    }
                }
            }

            let outcome: Outcome
            if rc == 0 {
                let issued = cStr(result.host_alt_irk_hex)
                if !issued.isEmpty { Self.storedAltIRK = issued }
                let devName = cStr(result.device_name)
                let filePath = cStr(result.pairing_file_path)
                outcome = .success(
                    name: devName.isEmpty ? "iPhone" : devName,
                    path: filePath.isEmpty ? outPath : filePath
                )
            } else {
                let msg = cStr(result.error)
                outcome = .failure(msg.isEmpty ? "pairing failed (rc=\(rc))" : msg)
            }
            al_pairing_result_free(&result)

            let box = RawPtrBox(ctx)
            DispatchQueue.main.async {
                Unmanaged<PairingController>.fromOpaque(box.ptr).release()
                self.finish(outcome)
            }
        }
    }

    private enum Outcome {
        case success(name: String, path: String)
        case failure(String)
    }

    private func finish(_ outcome: Outcome) {
        stopAdvertising()
        // Keep background alive for 5s so iOS doesn't kill the app before user returns from Settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.keepAlive.stopAll()
        }
        running = false
        pairingPIN = nil

        switch outcome {
        case let .success(name, path):
            let canonical = Self.syncCanonicalPairingFile(from: path)
            let size = (try? FileManager.default.attributesOfItem(atPath: canonical)[.size] as? Int) ?? 0
            if size == 0 {
                pairingStatus = "Failed: empty pairing file"
                resolve(.failure(PairingError.zeroBytes))
            } else {
                pairingStatus = "Paired: \(name) (\(size)B)"
                resolve(.success(canonical))
            }
        case let .failure(message):
            pairingStatus = "Failed: \(message)"
            resolve(.failure(PairingError.failed(message)))
        }
    }


    // MARK: Bonjour advertising

    fileprivate func startAdvertising(serviceID: String, port: Int32, txt: [String: Data]) {
        stopAdvertising()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: serviceID,
            port: port
        )
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        netService = service
        pairingStatus = "Advertising — open Settings › Privacy & Security › Developer Mode"
    }

    fileprivate func presentPin(_ pin: String) {
        pairingPIN = pin
        pairingStatus = "Enter PIN \(pin) in Settings › Privacy & Security › Developer Mode › Pair with Erosion"
    }

    private func stopAdvertising() {
        netService?.stop()
        netService = nil
    }
}

// MARK: - C callbacks

nonisolated(unsafe) private let pairReadyCallback: ALPairReadyCb = { ctx, serviceID, port, keys, vals, count in
    guard let ctx = ctx, let serviceID = serviceID else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let id = String(cString: serviceID)

    var txt: [String: Data] = [:]
    if let keys = keys, let vals = vals {
        for i in 0..<Int(count) {
            guard let k = keys[i], let v = vals[i] else { continue }
            txt[String(cString: k)] = Data(String(cString: v).utf8)
        }
    }
    DispatchQueue.main.async {
        controller.startAdvertising(serviceID: id, port: Int32(port), txt: txt)
    }
}

nonisolated(unsafe) private let pairPinCallback: ALPairPinCb = { pin, ctx in
    guard let ctx = ctx, let pin = pin else { return }
    let controller = Unmanaged<PairingController>.fromOpaque(ctx).takeUnretainedValue()
    let pinString = String(cString: pin)
    DispatchQueue.main.async {
        controller.presentPin(pinString)
    }
}

private func cStr(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
    guard let ptr = ptr else { return "" }
    return String(cString: ptr)
}


final class RawPtrBox: @unchecked Sendable {
    let ptr: UnsafeMutableRawPointer
    init(_ ptr: UnsafeMutableRawPointer) { self.ptr = ptr }
}
