import SwiftUI
import UIKit
import Combine
import QuickLook
import UniformTypeIdentifiers

struct AirliftView: View {
    @EnvironmentObject var airlift: AirliftBridge
    @State private var loopbackVPNUp: Bool = NetworkStatus.loopbackVPNUp()
    @State private var tunnelIP: String? = NetworkStatus.tunnelIP()
    @State private var deviceIP: String? = NetworkStatus.deviceIP()
    @State private var copied = false
    @State private var pairedTick = 0
    @State private var showPairingImporter = false

    private let ticker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            statusSection
            sessionSection
            pairingStatusSection
            pairingButtonsSection
            targetSection
            exploitSection
            readSection
            logSection
            appContainersSection
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
            .foregroundStyle(isPaired ? Color.secondary : Color.orange)
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
            }
            .foregroundStyle(.orange)
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
                    Text("View")
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

    private var appContainersSection: some View {
        NavigationLink {
            AirliftAppContainersView()
                .environmentObject(airlift)
        } label: {
            HStack {
                Label("App Containers", systemImage: "magnifyingglass")
                Spacer()
                if airlift.appScanRunning {
                    ProgressView()
                } else {
                    Text("\(airlift.installedAppContainers.count)")
                        .foregroundStyle(.secondary)
                }
            }
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
        airlift.maybeAutoScanInstalledAppContainers()
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
            let ext = localURL.pathExtension.lowercased()
            let extended = ["dylib", "bin", "so", "o", "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac"].contains(ext)
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
