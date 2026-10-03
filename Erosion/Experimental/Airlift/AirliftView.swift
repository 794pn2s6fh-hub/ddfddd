import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

struct AirliftView: View {
    @EnvironmentObject var airlift: AirliftBridge
    @State private var loopbackVPNUp: Bool = NetworkStatus.loopbackVPNUp()
    @State private var tunnelIP: String? = NetworkStatus.tunnelIP()
    @State private var deviceIP: String? = NetworkStatus.deviceIP()
    @State private var copied = false
    @State private var pairedTick = 0
    @State private var showPasscodeImporter = false
    @State private var showWalletImagePicker = false
    @State private var showPairingImporter = false
    @StateObject private var walletCards = WalletCardSkinManager()

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            statusSection
            sessionSection
            pairingStatusSection
            pairingButtonsSection
            passcodeSection
            walletCardsSection
            targetSection
            exploitSection
            readSection
            logSection
            logActionsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Airlift")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refresh(); pairedTick &+= 1 }
        .onReceive(ticker) { _ in refresh() }
        .onChange(of: airlift.state) { _, _ in pairedTick &+= 1 }
        .refreshable { refresh(); pairedTick &+= 1 }
        .sheet(isPresented: $airlift.showReadView) {
            NavigationStack {
                if let local = airlift.readViewLocalPath {
                    if airlift.readViewIsFolder {
                        FileBrowserView(
                            path: URL(fileURLWithPath: local, isDirectory: true),
                            readOnly: true,
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
        .sheet(isPresented: $showWalletImagePicker) {
            ImagePickerView { data in
                walletCards.setImageData(data)
            }
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
        .fileImporter(
            isPresented: $showPasscodeImporter,
            allowedContentTypes: [.archive, UTType(filenameExtension: "passthm") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            airlift.loadPasscodeTheme(url: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(loopbackVPNUp ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                        .frame(width: 72, height: 72)
                    Image(systemName: loopbackVPNUp ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(loopbackVPNUp ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("LocalDevVPN").font(.headline)
                    Text(loopbackVPNUp ? "Connected" : "Not connected")
                        .font(.subheadline)
                        .foregroundStyle(loopbackVPNUp ? .green : .orange)
                    if let t = tunnelIP {
                        Text("Tunnel \(t)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        } header: {
            Label("Current status", systemImage: "shield.lefthalf.filled")
        }
    }

    private var sessionSection: some View {
        Section {
            HStack {
                Text("Tunnel IP")
                Spacer()
                Text(tunnelIP ?? "\u{2014}")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(tunnelIP != nil ? .green : .secondary)
                    .shadow(color: tunnelIP != nil ? Color.green.opacity(0.55) : Color.clear, radius: 3)
            }
            HStack {
                Text("Device IP")
                Spacer()
                Text(deviceIP ?? "\u{2014}")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(deviceIP != nil ? .green : .secondary)
                    .shadow(color: deviceIP != nil ? Color.green.opacity(0.55) : Color.clear, radius: 3)
            }
        } header: {
            Label("Session details", systemImage: "network")
        }
    }

    private var pairingStatusSection: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(pairingColor.opacity(0.15))
                        .frame(width: 72, height: 72)
                    Image(systemName: pairingIcon)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(pairingColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(pairingTitle).font(.headline)
                    Text(pairingSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(pairingColor)
                        .lineLimit(2)
                    if airlift.pairPIN != nil {
                        Text("PIN \(airlift.pairPIN ?? "")")
                            .font(.system(size: 20, weight: .black, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        } header: {
            Label("Pairing", systemImage: "link.circle")
        }
    }

    private var pairingButtonsSection: some View {
        Section {
            if airlift.pairPIN != nil {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            }
            Button { airlift.runPairing() } label: {
                HStack {
                    Text(isPaired ? "Already Paired" : "Start Pairing")
                    Spacer()
                    if isPaired {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            .disabled(isPairing || isPaired)
            Button(role: .destructive) { airlift.cancelPairing() } label: {
                Text("Cancel Pairing")
            }
            .disabled(!isPairing)
            Button(role: .destructive) { airlift.deletePairing(); pairedTick &+= 1 } label: {
                Text("Delete Pairing")
            }
            .disabled(!isPaired)
            Button {
                showPairingImporter = true
            } label: {
                Text("Import Pairing File")
                    .foregroundStyle(.orange)
            }
        }
    }

    private var passcodeSection: some View {
        Section {
            HStack {
                Image(systemName: "lock.circle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(airlift.passcodeTheme?.name ?? "No theme loaded")
                    if let theme = airlift.passcodeTheme {
                        Text("\(theme.keys.count)/10 keys · \(theme.fileCount) assets")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Load a .passthm keypad theme")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Button {
                showPasscodeImporter = true
            } label: {
                Label("Choose .passthm", systemImage: "folder")
            }

            if airlift.passcodeTheme != nil {
                Picker("TelephonyUI", selection: $airlift.passcodeTelephonyVersion) {
                    Text("All versions").tag("all")
                    Text("TelephonyUI-10").tag("TelephonyUI-10")
                    Text("TelephonyUI-9").tag("TelephonyUI-9")
                    Text("TelephonyUI-8").tag("TelephonyUI-8")
                }

                Picker("Language", selection: $airlift.passcodeLanguage) {
                    Text("All languages").tag("all")
                    Text("English").tag("en")
                    Text("Ukrainian").tag("uk")
                    Text("Russian").tag("ru")
                    Text("Fallback only").tag("other")
                }

                Picker("Weight", selection: $airlift.passcodeBold) {
                    Text("Regular + Bold").tag("both")
                    Text("Bold only").tag("bold")
                    Text("Regular only").tag("regular")
                }

                Button {
                    airlift.flashPasscodeTheme()
                } label: {
                    HStack {
                        Text(airlift.passcodeFlashRunning ? "Applying…" : "Apply Passcode Theme")
                        Spacer()
                        if airlift.passcodeFlashRunning {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                    }
                }
                .disabled(airlift.passcodeFlashRunning || !airlift.hasPairing())

                Button(role: .destructive) {
                    airlift.clearPasscodeTheme()
                } label: {
                    Text("Clear Loaded Theme")
                }
            }

            if !airlift.passcodeFlashLog.isEmpty {
                ScrollView {
                    Text(airlift.passcodeFlashLog.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
        } header: {
            Label("Passcode", systemImage: "lock")
        } footer: {
            Text("This changes the passcode keypad artwork. It does not change the device passcode itself.")
        }
    }

    private var walletCardsSection: some View {
        Section {
            HStack {
                Image(systemName: "creditcard.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apple Pay Card Skins")
                    Text("Detect a Wallet card, choose artwork, and overwrite its local card-face cache.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button {
                    if walletCards.isScanning {
                        walletCards.stopScanning()
                    } else {
                        walletCards.startScanning()
                    }
                } label: {
                    Label(walletCards.isScanning ? "Stop Scan" : "Scan Cards",
                          systemImage: walletCards.isScanning ? "stop.circle.fill" : "wave.3.left.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(walletCards.isScanning ? .red : .orange)

                Spacer()

                Button("Select All") { walletCards.selectAll() }
                    .disabled(walletCards.cardIDs.isEmpty)
            }

            HStack {
                TextField("Card hash / identifier", text: $walletCards.manualCardID)
                    .font(.system(size: 12, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add") { walletCards.addManualCard() }
                    .disabled(walletCards.manualCardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !walletCards.cardIDs.isEmpty {
                ForEach(walletCards.cardIDs, id: \.self) { id in
                    Button {
                        walletCards.toggleSelected(id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: walletCards.selectedCardIDs.contains(id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(walletCards.selectedCardIDs.contains(id) ? .orange : .secondary)
                            Text(id)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if !walletCards.scanStatus.isEmpty {
                Text(walletCards.scanStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let data = walletCards.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        Button {
                            walletCards.clearImage()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                        }
                        .padding(8)
                    }
            }

            Button {
                showWalletImagePicker = true
            } label: {
                Label(walletCards.imageData == nil ? "Choose Card Artwork" : "Replace Card Artwork",
                      systemImage: "photo.on.rectangle")
            }

            Button {
                walletCards.applySelectedCards()
            } label: {
                HStack {
                    Text(walletCards.flashRunning ? "Overwriting…" : "Overwrite Apple Pay Cards")
                    Spacer()
                    if walletCards.flashRunning {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                }
            }
            .disabled(!walletCards.canApply)

            if !walletCards.flashLog.isEmpty {
                ScrollView {
                    Text(walletCards.flashLog.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        } header: {
            Label("Apple Pay / Wallet Cards", systemImage: "creditcard")
        } footer: {
            Text("Artwork only: this targets the Wallet card-face assets and does not change payment credentials.")
        }
    }

    private var targetSection: some View {
        Section {
            HStack {
                Text("Target")
                Spacer()
                TextField("/var/mobile/Library/SpringBoard", text: Binding(
                    get: { airlift.target }, set: { airlift.target = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Label("Target", systemImage: "scope")
        }
    }

    private var exploitSection: some View {
        Section {
            Button { airlift.runExploit() } label: {
                Text("Run Exploit")
            }
            .disabled(airlift.state == .running || !loopbackVPNUp || !isPaired)
            Button(role: .destructive) { airlift.cancelExploit() } label: {
                Text("Cancel Exploit")
            }
            .disabled(airlift.state != .running)
        } header: {
            Label("Exploit", systemImage: "cpu")
        }
    }

    private var readSection: some View {
        Section {
            Picker("Object", selection: $airlift.readKind) {
                ForEach(AirliftBridge.ReadKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }

            HStack {
                Text(airlift.readKind == .file ? "File" : "Folder")
                Spacer()
                TextField(airlift.readKind == .file ? "/var/mobile/.../file" : "/var/mobile/.../folder", text: Binding(
                    get: { airlift.readTarget }, set: { airlift.readTarget = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

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
                    Label("View", systemImage: "eye")
                }
                ShareLink(item: URL(fileURLWithPath: path)) {
                    Label(airlift.readKind == .folder ? "Export ZIP" : "Share Read File", systemImage: "square.and.arrow.up")
                }
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
            Label("Airlift Read / Folder", systemImage: "doc.text.magnifyingglass")
        } footer: {
            Text("Read snapshots are opened in Erosion's existing file browser. Edited files can be written back through Airlift.")
        }
    }

    private var logSection: some View {
        Section {
            AirliftLogTerminal(text: airlift.exploitLog.isEmpty
                        ? "No output yet."
                        : airlift.exploitLog.joined(separator: "\n"))
        } header: {
            Label("Log", systemImage: "terminal")
        }
    }

    private var logActionsSection: some View {
        Section {
            Button {
                UIPasteboard.general.string = airlift.exploitLog.joined(separator: "\n")
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Text(copied ? "Copied!" : "Copy All")
            }
            .disabled(airlift.exploitLog.isEmpty)
            Button(role: .destructive) { airlift.clearLog() } label: {
                Text("Clear")
            }
            .disabled(airlift.exploitLog.isEmpty)
        } header: {
            Label("Log Actions", systemImage: "document.on.document")
        }
    }

    private func refresh() {
        let vpn = NetworkStatus.loopbackVPNUp()
        let tun = NetworkStatus.tunnelIP()
        let dev = NetworkStatus.deviceIP()
        if loopbackVPNUp != vpn { loopbackVPNUp = vpn }
        if tunnelIP != tun { tunnelIP = tun }
        if deviceIP != dev { deviceIP = dev }
    }

    private var isPairing: Bool {
        if case .pairing = airlift.state { return true }
        return false
    }

    private var isPaired: Bool {
        _ = pairedTick
        return airlift.hasPairing()
    }

    private var pairingColor: Color {
        if isPaired { return .green }
        if isPairing { return .orange }
        if case .done(false, _) = airlift.state { return .red }
        return .secondary
    }

    private var pairingIcon: String {
        if isPaired { return "checkmark.seal.fill" }
        if isPairing { return "link.circle.fill" }
        if case .done(false, _) = airlift.state { return "xmark.seal.fill" }
        return "link.circle"
    }

    private var pairingTitle: String {
        if isPaired { return "Paired" }
        if isPairing { return "Pairing" }
        if case .done(false, _) = airlift.state { return "Failed" }
        return "Not Paired"
    }

    private var pairingSubtitle: String {
        if isPaired { return "Credentials saved" }
        if isPairing {
            return airlift.pairingStatus.isEmpty ? "Starting..." : airlift.pairingStatus
        }
        if case .done(false, let msg) = airlift.state { return msg }
        return "Open Settings to pair"
    }
}


private struct AirliftLogTerminal: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 200, maxHeight: 400)
    }
}


private struct AirliftReadFileView: View {
    let localURL: URL
    let remotePath: String

    var body: some View {
        Group {
            if conformsToPlistViewer(localURL) {
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
