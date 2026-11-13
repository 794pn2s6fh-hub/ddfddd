//
//  SettingsView.swift
//  Erosion
//
//  Created by lunginspector on 8/20/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var airlift: AirliftBridge
    @AppStorage("autoRespring") private var autoRespring = false
    @AppStorage("erosion.exploitSelection") private var exploitSelection = ErosionExploitSelection.both.rawValue
    @State private var isRunningExploitTest = false
    @State private var isPreparingPairingExport = false
    @State private var pairingExportItem: PairingExportItem?
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Auto-Respring", isOn: $autoRespring)
                } header: {
                    HeaderLabel("App Settings", symbol: "gearshape")
                } footer: {
                    Text("Automatically resprings your device after applying a tweak.")
                }

                Section {
                    if isIOS272Beta3OrLater() {
                        Text(ErosionExploitSelection.worseQuery.title)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Picker("", selection: $exploitSelection) {
                            ForEach(ErosionExploitSelection.allCases) { selection in
                                Text(selection.title).tag(selection.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Button("Run Exploit") {
                        runSelectedExploitTest()
                    }
                } header: {
                    HeaderLabel("Exploit", symbol: "wrench.and.screwdriver")
                }

                Section {
                    Link(destination: URL(string: "https://t.me/usrlibexec")!) {
                        AppInfoCell(build: "Release", appName: "Erosion mod", appVersion: "3.0")
                    }
                    .tint(.white)
                } header: {
                    HeaderLabel("About", symbol: "info.circle")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Made with love by the [jailbreak.party](https://jailbreak.party) team.\nNeed support or want to know about new releases? Join the [jailbreak.party Discord server!](https://jailbreak.party/discord)")
                    }
                }
                
                Section {
                    LinkCreditCell(image: Image("lunginspector"), name: "lunginspector", description: "Primary developer and maintainer.", url: "https://github.com/lunginspector")
                    LinkCreditCell(image: Image("forcequit"), name: "forcequit", description: "Developed and published bad_query sandbox escape.", url: "https://github.com/forcequitOS")
                    LinkCreditCell(image: Image("skadz108"), name: "Skadz", description: "Minor UI adjustments, respring implementation, and various backend functions.", url: "https://github.com/skadz108")
                    LinkCreditCell(image: Image("rooootdev"), name: "rooootdev", description: "Various backend components.", url: "https://github.com/rooootdev")
                    LinkCreditCell(image: Image("neonmodder123"), name: "neonmodder123", description: "Developed WebView respring method.", url: "https://github.com/neonmodder123")
                } header: {
                    HeaderLabel("Credits", symbol: "star")
                }

                Section {
                    if !isIOS272Beta3OrLater() {
                        Button {
                            preparePairingExport()
                        } label: {
                            HStack {
                                Text("Export Pairing")
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .tint(Color.accentColor)
                        .disabled(isPreparingPairingExport)
                        .sheet(item: $pairingExportItem, onDismiss: cleanupPairingExport) { item in
                            AirliftActivitySheet(items: [item.url])
                        }
                    }

                    Button(role: .destructive) {
                        Alertinator.shared.alert(
                            title: "Clear Erosion cache?",
                            body: "This removes Erosion's cached themes, prepared apps, snapshots, cached artwork, and temporary files.",
                            actionLabel: "Confirm",
                            actionStyle: .destructive,
                            action: {
                                if ErosionCacheCleaner.hasActiveOperation {
                                    Alertinator.shared.alert(
                                        title: "Cannot clear cache yet",
                                        body: "An Airlift read, write, pairing, exploit, passcode apply, or Wallet artwork operation is still running. Wait for it to finish, then try again."
                                    )
                                    return
                                }
                                let result = ErosionCacheCleaner.clear()
                                Alertinator.shared.alert(title: result.title, body: result.message)
                            }
                        )
                    } label: {
                        Text("Clear Cache")
                    }
                    .tint(.red)
                } header: {
                    HeaderLabel("Actions", symbol: "slider.horizontal.3")
                }
            }
            .navigationTitle("Settings")
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
    }

    private var exploitTestUnavailable: Bool {
        ErosionCacheCleaner.hasActiveOperation
            || airlift.containerScansRunning
            || airlift.appScanRunning
            || airlift.appGroupPathScanRunning
    }

    private func runSelectedExploitTest() {
        guard !isRunningExploitTest, !exploitTestUnavailable else { return }
        let selection = effectiveExploitSelection(for: exploitSelection)
        isRunningExploitTest = true

        Task { @MainActor in
            switch selection {
            case .both:
                let worseQuerySucceeded = await runWorseQueryProbe()
                print(worseQuerySucceeded
                      ? "[+] worse_query: success"
                      : "[!] worse_query: failed")

                let airliftSucceeded = await runAirliftProbe()
                print(airliftSucceeded
                      ? "[+] Airlift: success"
                      : "[!] Airlift: failed")

            case .worseQuery:
                let succeeded = await runWorseQueryProbe()
                print(succeeded
                      ? "[+] worse_query: success"
                      : "[!] worse_query: failed")

            case .airlift:
                let succeeded = await runAirliftProbe()
                print(succeeded
                      ? "[+] Airlift: success"
                      : "[!] Airlift: failed")
            }
            isRunningExploitTest = false
        }
    }

    /// Checks Worse Query against the exact configuration-profile cache path.
    /// The check only acquires and releases access; it does not read or modify contents.
    private func runWorseQueryProbe() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let targetPath = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/Caches"
            let access = wq.grantAccess(path: targetPath)
            defer {
                if access.1 >= 0 { worse_query_release(access.1) }
            }
            return access.0 && access.1 >= 0
        }.value
    }

    /// Runs the full Airlift exploit/canary transaction, not an AFC-only probe.
    private func runAirliftProbe() async -> Bool {
        await withCheckedContinuation { continuation in
            airlift.runExploit(logDetails: false) { succeeded in
                continuation.resume(returning: succeeded)
            }
        }
    }

    private func preparePairingExport() {
        guard !isPreparingPairingExport else { return }
        isPreparingPairingExport = true

        // PairingController may recover/validate files in Documents. Resolve it
        // only after the user taps Export and never as part of Settings rendering.
        Task { @MainActor in
            let activePath = await Task.detached(priority: .utility) { () -> String? in
                let path = AirliftBridge.shared.pairingFilePath()
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path),
                      FileManager.default.isReadableFile(atPath: url.path),
                      let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                      !data.isEmpty else { return nil }
                return url.path
            }.value

            isPreparingPairingExport = false
            guard let activePath else {
                Alertinator.shared.alert(
                    title: "Export Pairing unavailable",
                    body: "Airlift's active pairing file is missing or unreadable. Import or create a pairing first."
                )
                return
            }

            PairingController.customPairingFilePath = activePath
            UserDefaults.standard.set(activePath, forKey: "erosionPairingActiveFilePath")
            pairingExportItem = PairingExportItem(url: URL(fileURLWithPath: activePath))
        }
    }

    private func cleanupPairingExport() {
        pairingExportItem = nil
    }
}


/// Removes only Erosion-owned persistent libraries and cache directories.
/// The Documents root is never removed, so the Airlift pairing file and other
/// unrelated files in Documents remain untouched.
private enum ErosionCacheCleaner {
    static var hasActiveOperation: Bool {
        let airlift = AirliftBridge.shared
        switch airlift.state {
        case .pairing, .running:
            return true
        default:
            break
        }
        return airlift.readRunning
            || airlift.passcodeFlashRunning
            || (WalletCardSkinManager.shared?.flashRunning ?? false)
            || (WalletCardSkinManager.shared?.isReadingArtworks ?? false)
    }

    static func clear() -> (title: String, message: String) {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL.documentsDirectory

        let targets: [URL] = [
            AppURL.pb,
            AppURL.ps,
            support.appendingPathComponent("ErosionPasscodeLibrary", isDirectory: true),
            support.appendingPathComponent("ErosionAppsManagement", isDirectory: true),
            support.appendingPathComponent("ErosionFileOperationsSnapshots", isDirectory: true),
            caches.appendingPathComponent("ErosionThemingPreviews", isDirectory: true)
        ]

        var removed = 0
        var failures: [String] = []
        for target in targets {
            guard fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.removeItem(at: target)
                removed += 1
            } catch {
                failures.append("\(target.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Clear the app's tmp contents, not the tmp directory itself. Keep the
        // silent audio resource while KeepAlive is actively using it.
        do {
            let temporaryItems = try fileManager.contentsOfDirectory(
                at: fileManager.temporaryDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            for item in temporaryItems {
                if item.lastPathComponent == "keepalive.wav" && KeepAlive.shared.audioActive {
                    continue
                }
                do {
                    try fileManager.removeItem(at: item)
                    removed += 1
                } catch {
                    failures.append("\(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            failures.append("tmp: \(error.localizedDescription)")
        }

        // Remove only Erosion theme archives from Documents; never remove the
        // Documents root or the active Airlift pairing file.
        if let documentItems = try? fileManager.contentsOfDirectory(
            at: documents,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for item in documentItems where item.pathExtension.lowercased() == "passthm" {
                do {
                    try fileManager.removeItem(at: item)
                    removed += 1
                } catch {
                    failures.append("\(item.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        let defaults = UserDefaults.standard
        let keys = [
            "tendiesArray",
            "erosion.passcodeLibrary.selectedFilename",
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        if failures.isEmpty {
            return (
                "Cache cleared",
                "Removed \(removed) Erosion data item(s). Restart Erosion to refresh data that was already loaded in memory."
            )
        }
        return (
            "Cache partially cleared",
            "Removed \(removed) item(s). Could not remove: \(failures.joined(separator: "; "))."
        )
    }
}
