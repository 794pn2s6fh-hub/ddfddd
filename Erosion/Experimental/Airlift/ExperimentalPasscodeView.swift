import SwiftUI
import UniformTypeIdentifiers

struct ExperimentalPasscodeView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var showImporter = false

    var body: some View {
        Group {
            if airliftUIAccessRequired() && !(airlift.airliftFeatureReady()) {
                ContentUnavailableView("Airlift required", systemImage: "link.circle", description: Text("Enable LocalDevVPN and import a valid pairing file in Airlift."))
            } else {
                List {
            Section {
                HStack {
                    Image(systemName: "lock.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(airlift.passcodeTheme?.name ?? "No theme loaded")
                        if let theme = airlift.passcodeTheme {
                            Text("\(theme.keys.count)/10 keys · \(theme.fileCount) assets")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Load a .passthm keypad theme")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                Button { showImporter = true } label: {
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
                    Button { airlift.flashPasscodeTheme() } label: {
                        HStack {
                            Text(airlift.passcodeFlashRunning ? "Applying…" : "Apply Passcode Theme")
                            Spacer()
                            if airlift.passcodeFlashRunning { ProgressView() } else { Image(systemName: "arrow.down.circle.fill") }
                        }
                    }
                    .disabled(airlift.passcodeFlashRunning || !(airlift.airliftFeatureReady()))
                    Button(role: .destructive) { airlift.clearPasscodeTheme() } label: {
                        Text("Clear Loaded Theme")
                    }
                }
            } header: {
                Label("Custom Passcode", systemImage: "lock")
            } footer: {
                Text("This changes the passcode keypad artwork. It does not change the device passcode itself.")
            }
            if !airlift.passcodeFlashLog.isEmpty {
                Section("Log") {
                    ScrollView {
                        Text(airlift.passcodeFlashLog.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 220)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Custom Passcode")
        .navigationBarTitleDisplayMode(.inline)
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.archive, UTType(filenameExtension: "passthm") ?? .data], allowsMultipleSelection: false) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    airlift.loadPasscodeTheme(url: url)
                    if scoped { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }
}
