import SwiftUI
import UIKit
import Combine
import QuickLook
import UniformTypeIdentifiers

private struct PairingExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func hideAirliftSharedBackgroundIfAvailable() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

struct AirliftView: View {
    @EnvironmentObject var airlift: AirliftBridge
    // Network state is sampled once the screen appears. Initializing these values
    // with three independent getifaddrs scans was needless synchronous work while
    // SwiftUI was constructing navigation destinations.
    @State private var loopbackVPNUp = false
    @State private var tunnelIP: String? = nil
    @State private var deviceIP: String? = nil
    @State private var isVisible = false
    @State private var pairedTick = 0
    @State private var showPairingImporter = false
    @State private var showPairingInstructions = false
    @State private var showAirliftNote = false
    @State private var pairingRefreshTick = 0
    @State private var lastObservedPairPIN: String? = nil
    @State private var pairingExportItem: PairingExportItem?

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    // PairingController's PIN is a plain property rather than @Published.
    // Poll it for UI display while pairing so the toolbar title cannot miss a short PIN update.
    private let pairingTicker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            pairingSection
            connectionSection
            targetSection
            readSection
            logSection
            otherSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Airlift")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if isPaired {
                // Keep the help button's original native toolbar capsule/background.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAirliftNote = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .tint(.primary)
                    .accessibilityLabel("Airlift note")
                }
            } else {
                // Hide only the toolbar's extra shared glass layer behind Pair.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if isPairing {
                            airlift.cancelPairing()
                            lastObservedPairPIN = nil
                            pairedTick &+= 1
                        } else {
                            airlift.runPairing()
                            showPairingInstructions = true
                        }
                    } label: {
                        Text(pairButtonTitle)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.black)
                            .frame(minWidth: 44)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background {
                                if #available(iOS 26.0, *) {
                                    Capsule()
                                        .fill(Color.clear)
                                        .glassEffect(
                                            .regular.interactive().tint(pairButtonTint),
                                            in: .capsule
                                        )
                                } else {
                                    Capsule().fill(pairButtonTint)
                                }
                            }
                            .contentTransition(.identity)
                            .animation(.spring(response: 0.30, dampingFraction: 0.88), value: isPairing)
                            .animation(.easeInOut(duration: 0.22), value: hasLivePairPIN)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pairButtonTitle)
                }
                .hideAirliftSharedBackgroundIfAvailable()
            }
        }
        .sheet(isPresented: $showAirliftNote) {
            AirliftNoteView()
        }
        .alert("Pairing…", isPresented: $showPairingInstructions) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Go to Settings —> Privacy & Security —> Developer Mode —> Pair with Erosion")
        }
        .onAppear {
            isVisible = true
            refresh()
            pairedTick &+= 1
            airlift.autoScanContainerDiagnosticsOnEntry()
        }
        .onDisappear {
            isVisible = false
        }
        .onReceive(ticker) { _ in
            // NavigationLink destinations may be constructed before they are shown.
            // Do not poll interfaces or trigger scans while the Airlift screen is hidden.
            guard isVisible else { return }
            refresh()
        }
        .onReceive(pairingTicker) { _ in
            guard isVisible, isPairing else { return }
            let currentPIN = PairingController.shared.pairingPIN ?? airlift.pairPIN
            guard currentPIN != lastObservedPairPIN else { return }
            lastObservedPairPIN = currentPIN
            pairingRefreshTick &+= 1
        }
        .onChange(of: airlift.state) { _, _ in
            pairedTick &+= 1
            if isVisible { airlift.maybeAutoScanInstalledAppContainers() }
        }
        .refreshable { refresh(); pairedTick &+= 1 }
        .sheet(isPresented: $airlift.showReadView) {
            NavigationStack {
                if let local = airlift.readViewLocalPath {
                    if airlift.readViewIsFolder {
                        FileBrowserView(
                            path: URL(fileURLWithPath: local, isDirectory: true),
                            readOnly: false,
                            navigationTitleOverride: URL(fileURLWithPath: airlift.readViewRemotePath ?? local).lastPathComponent,
                            airliftRemoteRoot: airlift.readViewRemotePath,
                            airliftLocalRoot: local
                        )
                    } else {
                        AirliftReadFileView(
                            localURL: URL(fileURLWithPath: local),
                            remotePath: airlift.readViewRemotePath ?? airlift.readTarget
                        )
                    }
                } else {
                    ContentUnavailableView("No read snapshot", systemImage: "doc.questionmark")
                }
            }
            .environmentObject(airlift)
        }
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: [.propertyList, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    airlift.importPairingFile(from: url)
                    pairedTick &+= 1
                }
            case .failure(let error):
                airlift.importPairingFileError(error)
            }
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                showPairingImporter = true
            } label: {
                HStack {
                    Text("Import Pairing")
                        .foregroundStyle(isPaired ? Color.secondary : Color.orange)
                    Spacer()
                    if isPaired {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.green)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPaired)

            Button(role: .destructive) {
                airlift.deletePairing()
                pairedTick &+= 1
            } label: {
                Text("Delete Pairing")
            }
            .disabled(!isPaired)
        } header: {
            HeaderLabel("Pairing", symbol: "doc.text")
        }
    }

    private var connectionSection: some View {
        Section {
            HStack {
                if loopbackVPNUp, let connectedIP = tunnelIP ?? deviceIP {
                    Text(connectedIP)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.green)
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(.green)
                } else {
                    Text("\u{2014}")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        } header: {
            HeaderLabel("Connection", symbol: "link.circle")
        }
    }

    private var targetSection: some View {
        Section {
            HStack(spacing: 12) {
                Text("Path")
                Spacer(minLength: 8)
                TextField("/var/mobile/Library/SpringBoard", text: Binding(
                    get: { airlift.readTarget }, set: { airlift.readTarget = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            HStack(spacing: 12) {
                Text("Object")
                Spacer(minLength: 8)
                Picker("Object", selection: $airlift.readKind) {
                    ForEach(AirliftBridge.ReadKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        } header: {
            HeaderLabel("Target", symbol: "scope")
        }
    }

    private var readSection: some View {
        Section {
            Button {
                airlift.runExploit()
            } label: {
                Text("Run Exploit")
            }
            .disabled(airlift.state == .running || !loopbackVPNUp || !isPaired)

            Button {
                if airlift.readKind == .file {
                    airlift.readRemoteFile()
                } else {
                    airlift.readRemoteFolder()
                }
            } label: {
                HStack {
                    Text(airlift.readRunning ? (airlift.readKind == .file ? "Reading…" : "Reading folder…") : (airlift.readKind == .file ? "Read File" : "Read Folder"))
                    Spacer()
                    if airlift.readRunning { ProgressView() }
                }
            }
            .disabled(airlift.readRunning || !loopbackVPNUp || !isPaired)

            if let path = airlift.readExportPath, FileManager.default.fileExists(atPath: path) {
                Button { airlift.openReadView() } label: {
                    Text(airlift.readKind == .folder ? "View Folder" : "View File")
                }
                ShareLink(item: URL(fileURLWithPath: path)) {
                    Text(airlift.readKind == .folder ? "Export Folder" : "Export File")
                }
            } else {
                Button(airlift.readKind == .folder ? "View Folder" : "View File") { }
                    .disabled(true)
                Button(airlift.readKind == .folder ? "Export Folder" : "Export File") { }
                    .disabled(true)
            }

            if !airlift.readResult.isEmpty {
                ScrollView {
                    Text(airlift.readResult)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
        } header: {
            HeaderLabel("Actions", symbol: "bolt")
        } footer: {
            Text("Read snapshots are opened in Erosion's existing file browser. Edited files can be written back through Airlift.")
        }
    }

    private var logSection: some View {
        Section {
            ScrollView(showsIndicators: false) {
                Text(airlift.exploitLog.isEmpty
                     ? "No output yet."
                     : airlift.exploitLog.joined(separator: "\n"))
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().id(0)
            }
            // Give the log text about 5% more usable width without changing the platter width.
            .padding(.horizontal, 6)
            .padding(.top, 18)
            .padding(.bottom, 14)
            // About 10% taller than the previous 270 pt Airlift log area.
            .frame(height: 297)
            .padding(.horizontal)
            .background(Color(.quaternarySystemFill), in: .rect(cornerRadius: logPlatterRad))
        .contextMenu {
                Button {
                    Haptic.shared.play(.soft)
                    UIPasteboard.general.string = airlift.exploitLog.joined(separator: "\n")
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc")
                }

                Button {
                    do {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "MM-dd-yyyy-HHmmss"
                        let date = formatter.string(from: Date())
                        let tempURL = URL.temporaryDirectory
                            .appendingPathComponent("Airlift-Log-\(date)")
                            .appendingPathExtension("txt")
                        let logData = Data(airlift.exploitLog.joined(separator: "\n").utf8)
                        try logData.write(to: tempURL)
                        presentShareSheet(with: tempURL)
                    } catch {
                        print("(airlift) failed to export logs: \(error.localizedDescription)")
                    }
                } label: {
                    Label("Export Logs", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            HeaderLabel("Logs", symbol: "apple.terminal")
        }
    }

    private var otherSection: some View {
        Section {
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
            .disabled(!isPaired)
            // Attach export presentation to this action, rather than the parent that
            // already owns several unrelated sheets.
            .sheet(item: $pairingExportItem, onDismiss: cleanupPairingExport) { item in
                AirliftActivitySheet(items: [item.url])
            }

            Button(role: .destructive) {
                Alertinator.shared.alert(
                    title: "Clear tmp?",
                    body: "This removes everything inside Erosion's app temporary directory (the tmp folder shown in Airlift staging paths). Do not run it while a read, write, exploit, or theme operation is active.",
                    actionLabel: "Clear tmp",
                    action: {
                        if temporaryWorkInProgress {
                            Alertinator.shared.alert(
                                title: "Cannot clear tmp yet",
                                body: "An Airlift read, write, exploit, passcode apply, or container scan is still running. Wait for it to finish, then try again."
                            )
                            return
                        }
                        let result = clearAirliftTemporaryDirectory()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            Alertinator.shared.alert(title: result.title, body: result.message)
                        }
                    }
                )
            } label: {
                HStack {
                    Text("Clear tmp")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        } header: {
            HeaderLabel("Other", symbol: "ellipsis")
        }
    }

    private var temporaryWorkInProgress: Bool {
        if case .running = airlift.state { return true }
        return airlift.readRunning
            || airlift.passcodeFlashRunning
            || airlift.containerScansRunning
            || (WalletCardSkinManager.shared?.flashRunning ?? false)
            || (WalletCardSkinManager.shared?.isScanning ?? false)
            || (WalletCardSkinManager.shared?.isReadingArtworks ?? false)
    }

    private func clearAirliftTemporaryDirectory() -> (title: String, message: String) {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        do {
            let entries = try fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
            var removed = 0
            var failures: [String] = []
            for entry in entries {
                do {
                    try fileManager.removeItem(at: entry)
                    removed += 1
                } catch {
                    failures.append("\(entry.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if failures.isEmpty {
                return ("/tmp cleared", "Removed \(removed) item(s) from Erosion's temporary directory.")
            }
            return ("/tmp partially cleared", "Removed \(removed) item(s). Could not remove: \(failures.joined(separator: "; "))")
        } catch {
            return ("Could not clear /tmp", error.localizedDescription)
        }
    }

    private func preparePairingExport() {
        let fileManager = FileManager.default
        // Always resolve the same path that read/write/exploit use. Do not reject
        // the active record with a second, stricter UI-only validation step.
        let activeURL = URL(fileURLWithPath: airlift.pairingFilePath()).standardizedFileURL
        guard fileManager.fileExists(atPath: activeURL.path),
              fileManager.isReadableFile(atPath: activeURL.path),
              let data = try? Data(contentsOf: activeURL, options: [.mappedIfSafe]),
              !data.isEmpty else {
            Alertinator.shared.alert(
                title: "Export Pairing unavailable",
                body: "Airlift's active pairing file is missing or unreadable. Import or create a pairing first."
            )
            return
        }

        // Share the exact active file from Documents. This avoids the old strict
        // dictionary scan and temporary snapshot, and it remains untouched on dismiss.
        PairingController.customPairingFilePath = activeURL.path
        UserDefaults.standard.set(activeURL.path, forKey: "erosionPairingActiveFilePath")
        pairingExportItem = PairingExportItem(url: activeURL)
    }

    private func cleanupPairingExport() {
        // The item is the original active pairing file; do not remove it.
        pairingExportItem = nil
    }

    private func refresh() {
        // One interface walk yields all three labels. The old implementation called
        // getifaddrs independently for VPN status, tunnel IP, and device IP on each
        // 0.5-second tick, including while a constructed destination was hidden.
        let pairs = NetworkStatus.tunnelPairs()
        let vpn = !pairs.isEmpty
        let tun = pairs.first(where: { $0.peer != nil })?.peer
        let dev = pairs.first?.local
        let becameAvailable = !loopbackVPNUp && vpn
        if loopbackVPNUp != vpn { loopbackVPNUp = vpn }
        if tunnelIP != tun { tunnelIP = tun }
        if deviceIP != dev { deviceIP = dev }
        if becameAvailable { airlift.maybeAutoScanInstalledAppContainers() }
    }

    private var isPaired: Bool {
        _ = pairedTick
        return airlift.hasPairing()
    }

    private var isPairing: Bool {
        if case .pairing = airlift.state { return true }
        return false
    }

    private var pairButtonTint: Color {
        isPairing && !hasLivePairPIN ? Color(.systemGray4) : Color.accentColor
    }

    private var livePairPIN: String? {
        _ = pairingRefreshTick
        // Read the controller directly as a fallback: the bridge mirrors its PIN
        // asynchronously, and can otherwise miss the brief update between polls.
        return PairingController.shared.pairingPIN ?? airlift.pairPIN
    }

    private var hasLivePairPIN: Bool {
        guard let pin = livePairPIN else { return false }
        return !pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pairButtonTitle: String {
        if isPairing {
            return hasLivePairPIN ? (livePairPIN ?? "Pairing…") : "Pairing…"
        }
        return "Pair"
    }

}


private struct AirliftReadFileView: View {
    let localURL: URL
    let remotePath: String

    var body: some View {
        Group {
            let ext = localURL.pathExtension.lowercased()
            let extended = ["dylib", "bin", "so", "o", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac", "pdf"].contains(ext)
            if extended {
                FilePreviewView(url: localURL, remotePath: remotePath, remoteWritable: false)
            } else if conformsToPlistViewer(localURL) {
                PlistViewer(localURL, remotePath: remotePath)
            } else if conformsToTextViewer(localURL) {
                TextViewer(localURL, remotePath: remotePath)
            } else {
                QuickLookAirliftFileView(url: localURL)
            }
        }
    }
}

private struct QuickLookAirliftFileView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass").font(.largeTitle)
            Text(url.lastPathComponent).font(.headline)
            Text("Read-only snapshot").foregroundStyle(.secondary)
            Button { previewURL = url } label: { Label("Preview", systemImage: "eye") }
            ShareLink(item: url) { Label("Share / Export", systemImage: "square.and.arrow.up") }
        }
        .padding()
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        .quickLookPreview($previewURL)
        .onAppear { previewURL = url }
    }
}

private struct AirliftNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private let noteText = """
Airlift note.
Please DO NOT leave Erosion mod while reading a path. That is NOT direct read and you may lose your data. It can be extremely dangerous sometimes. Airlift has access to following paths:
=====
R/W (?)
=====
/var/mobile/Library/Accounts/
/var/mobile/Library/Mail/
/var/mobile/Library/Shortcuts/
/var/mobile/Library/FrontBoard/
/var/mobile/Library/BackBoard/
/var/mobile/Library/Logs/
/var/mobile/Library/VoiceServices/
/var/mobile/Library/HTTPStorages/
/var/mobile/Library/Saved Application State/
/var/mobile/Library/DuetActivityScheduler/
/var/mobile/Library/Spotlight/
/var/mobile/Library/Biome/
/var/mobile/Library/GameKit/
/var/mobile/Library/AddressBook/
/var/mobile/Library/Contacts/
/var/mobile/Library/Calendar/
/var/mobile/Library/Reminders/
/var/mobile/Library/Cookies/
/var/mobile/Library/WebKit/
/var/mobile/Library/SpringBoard
/var/mobile/Library/Carrier Bundles/
/var/mobile/Library/Safari/
/var/mobile/Library/com.apple.private.SensorKit
/var/mobile/Library/Passes (needs fix)
/var/mobile/Library/SplashBoard/Snapshots/
/var/mobile/Library/CallServices
/var/mobile/Library/UserNotifications/
/var/mobile/Library/StatusKit/
/var/mobile/Library/BulletinBoard/
/var/mobile/Library/OSAnalytics/
/var/mobile/Library/ApplicationSync/
/var/mobile/Library/IdentityServices/
/var/mobile/Library/Suggestions/
/var/mobile/Library/com.apple.icloud.searchpartyd/
/var/mobile/Library/Accessibility/
/var/mobile/Library/DiagnosticPipeline/
/var/mobile/Library/com.apple.itunesstored/
/var/mobile/Library/CallHistoryDB/
/var/mobile/Library/Health/
/var/mobile/Library/MediaStream/
/var/mobile/Library/PersonalizationPortrait/
/var/mobile/Library/LASD/
/var/mobile/Library/CoreAS/
/var/mobile/Library/AggregateDictionary/
/var/mobile/Library/com.apple.FamilyControlsAgent/
/var/mobile/Library/com.apple.VideoSubscriberAccount.DeveloperService/
/var/mobile/Library/NFStorage/
/var/mobile/Library/Notes/
/var/mobile/Library/ExposureNotification/
/var/mobile/Library/Sharing/
/var/mobile/Library/TCC/
/var/mobile/Library/SecureElementService/
/var/mobile/Library/Avatar/
/var/mobile/Library/idcredd/
/var/mobile/Library/LanguageModeling/
/var/mobile/Library/chronod/
/var/mobile/Library/Handwriting/
/var/mobile/Library/ApplePushService/
/var/mobile/Library/PowerUI/
/var/mobile/Library/ClassKit/
/var/mobile/Library/Recents/
/var/mobile/Library/CoreDuet/
/var/mobile/Library/CountryBundles/
/var/mobile/Library/KeyboardServices/
/var/mobile/Library/com.apple.iTunesCloud/
/var/mobile/Library/DeviceRegistry.state/
/var/mobile/Library/News/
/var/mobile/Library/Translation/
/var/mobile/Library/com.apple.nsurlsessiond-launchd/
/var/mobile/Library/com.apple.appleaccountd/
/var/mobile/Library/com.apple.managedconfiguration.ManagedSettingsExtension/
/var/mobile/Library/PrivacyAccounting/
/var/mobile/Library/DataDeliveryServices/
/var/mobile/Library/Photos/
/var/mobile/Library/Voicemail/
/var/mobile/Library/MediaRemote/
/var/mobile/Library/DeviceRegistry.dontBackUp/
/var/mobile/Library/ControlCenter/
/var/mobile/Library/MedicalID
/var/mobile/Library/CoreAccessories/
/var/mobile/Library/MessagesMetaData/
/var/mobile/Library/mad/
/var/mobile/Library/com.apple.assistant.Contacts/
/var/mobile/Library/AirPlayRoutePrediction/
/var/mobile/Library/SoftwareUpdateCore/
/var/mobile/Library/FinHealth/
/var/mobile/Library/OnDemandResources/
/var/mobile/Library/RelevanceEngine/
/var/mobile/Library/com.apple.ManagedSettings/
/var/mobile/Library/VoiceTrigger/
/var/mobile/Library/PeopleSuggester/
/var/mobile/Library/CallHistoryTransactions/
/var/mobile/Library/DataAccess/
/var/mobile/Library/Intents/
/var/mobile/Library/WatchConnectivity/
/var/mobile/Library/CoreFollowUp/
/var/mobile/Library/UserNotificationsUI/
/var/mobile/Library/CallDirectory/
/var/mobile/Library/FairPlay/
/var/mobile/Library/UserFonts/
/var/mobile/Library/Preferences/com.apple.Preferences.plist
/var/mobile/Library/Preferences/com.apple.purplebuddy.plist
/var/mobile/Library/Preferences/com.apple.locationd.plist
/var/mobile/Library/Preferences/com.apple.springboard.plist
/var/mobile/Library/Preferences/com.apple.voiceservices.plist
/var/mobile/Library/Preferences/com.apple.assistant.plist
/var/mobile/Documents/
/var/mobile/Downloads/
/var/mobile/Media/DCIM/
/var/mobile/Media/PhotoData/ (very slow)
/var/mobile/Media/iTunes_Control/
/var/mobile/Media/Downloads/
/var/mobile/Media/Podcasts/
/var/mobile/Media/Books/
/var/mobile/Library/SMS/Drafts/
/var/mobile/.forward
/var/mobile/Containers/Data/Application/UUID/ (may be broken and very dangerous)
/var/mobile/Containers/Data/InternalDaemon/UUID/<folder/file you want to search>/
/var/mobile/Containers/Data/PluginKitPlugin/UUID/<folder/file you want to search>/
/var/mobile/Containers/Shared/AppGroup/UUID/<folder/file you want to search>/
=========
READ ONLY
=========
/var/MobileDevice/
/var/msgs/
/var/empty/
/var/folders/
/var/MobileSoftwareUpdate/MobileAsset/
/var/installd/Library/MobileInstallation/UninstalledApplications.plist
/var/installd/Library/MobileInstallation/LastBuildInfo.plist
/var/installd/Library/Logs/MobileInstallation/
/var/installd/Library/Caches/com.apple.mobile.installd.staging/
/var/staged_system_apps/
/var/buddy/
/var/select/
/var/root/Library/Preferences/com.apple.MobileAsset.plist
/var/root/Library/Catacomb/
/var/root/Library/Logs/
/var/root/Library/Backup/
/var/root/Library/HTTPStorages/
/var/root/Library/com.apple.wifianalyticsd/
/var/root/Library/Application Support/
/var/db/findmydevice/
/var/db/uuidtext/
/var/db/systemstats/
/var/db/timezone/
/var/db/MobileIdentityData/
/var/db/com.apple.xpc.launchd/
/var/preferences/Logging/
/var/preferences/SystemConfiguration/
/var/wireless/Library/Logs/
/var/wireless/Library/LASD/
/var/wireless/Library/Databases/
/var/wireless/Library/HTTPStorages/
/var/logs/AppleSupport/
/var/logs/CrashReporter/
---------------------
I am pretty sure that this is not full list of paths so you can try other paths too. Please use read at your own risk.
"""

    private var displayedText: String {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return noteText }
        let matches = noteText.components(separatedBy: .newlines).filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        return matches.isEmpty ? "No matches for \(query)." : matches.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(displayedText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .searchable(text: $searchText, prompt: "Search paths or words")
            .navigationTitle("Airlift Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}



private struct AirliftActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
