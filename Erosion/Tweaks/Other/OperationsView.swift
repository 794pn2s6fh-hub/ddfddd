//
//  OperationsView.swift
//  Erosion
//
//  Created by lunginspector on 8/17/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct OperationsView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var directory = ""
    @State private var fileName = ""
    @State private var isAcc = false
    @State private var showImporter = false
    @State private var showAirliftReadKindChooser = false
    @State private var airliftOperationRunning = false
    @State private var airliftTargetKind: AirliftBridge.ReadKind?
    @State private var airliftSnapshotURL: URL?

    @State private var imprtName = ""
    @State private var imprtData = Data()

    var body: some View {
        List {
            Section {
                TextField("Directory", text: $directory)
                    .disabled(isAcc || airliftOperationRunning)
                TextField("File Name", text: $fileName)
                    .disabled(isAcc || airliftOperationRunning)
                HStack {
                    Button("Grant Access") {
                        if isAirliftCompatibilityMode() {
                            // Ask for the object type before invoking either Airlift reader.
                            showAirliftReadKindChooser = true
                        } else {
                            let res = bq.grantAccess(atPath: directory, toFileName: fileName)
                            if !res.0 {
                                Alertinator.shared.alert(title: "Failed to get access to target file!", body: "\(res.1): \(res.2)")
                            } else {
                                isAcc = true
                            }
                        }
                    }
                    .disabled(isAcc || airliftOperationRunning)
                    if isAcc {
                        Spacer()
                        HStack {
                            Image(systemName: "checkmark")
                            Text("Access Granted")
                        }
                        .foregroundStyle(.green)
                    }
                }
                if isAcc {
                    Button("Change Path", role: .destructive) {
                        resetTargetState()
                    }
                    .disabled(airliftOperationRunning)

                    Button("Export File") {
                        if isAirliftCompatibilityMode() {
                            exportSavedAirliftSnapshot()
                        } else {
                            let fileDir = "\(directory)/\(fileName)"
                            presentShareSheet(with: URL(fileURLWithPath: fileDir))
                        }
                    }
                    .disabled(airliftOperationRunning)
                }
            } header: {
                HeaderLabel("Target", symbol: "dot.scope")
            }

            Section {
                HStack {
                    Button("Import File") {
                        showImporter = true
                    }
                    .disabled(!imprtData.isEmpty || airliftOperationRunning)
                    if !imprtName.isEmpty {
                        Spacer()
                        Text(imprtName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Button("Overwrite File") {
                    if isAirliftCompatibilityMode() {
                        overwriteAirliftTarget()
                        return
                    }
                    do {
                        let targetURL = URL(fileURLWithPath: "\(directory)/\(fileName)")
                        try imprtData.write(to: targetURL)
                        print("(ov) successfully overwrote file: \(targetURL.path) (\(imprtData.count))")
                        Haptic.shared.play(.soft)
                    } catch {
                        print("(ov) failed to overwrite: \(error.localizedDescription)")
                        Alertinator.shared.alert(title: "Failed to overwrite file!", body: "Make sure that your paths are correct and that you have access. Check error logs for more detailed information.")
                    }
                }
                .disabled(
                    !isAirliftCompatibilityMode()
                        ? imprtData.isEmpty
                        : (!isAcc || airliftTargetKind != .file || imprtData.isEmpty || airliftOperationRunning)
                )

                Button("Move File") {
                    if isAirliftCompatibilityMode() {
                        moveAirliftFile()
                        return
                    }
                    do {
                        let targetURL = URL(fileURLWithPath: "\(directory)").appendingPathComponent(imprtName)
                        try imprtData.write(to: targetURL)
                        print("(ov) successfully moved file: \(imprtName) -> \(targetURL.path)")
                        Haptic.shared.play(.soft)
                    } catch {
                        print("(ov) failed to move: \(error.localizedDescription)")
                        Alertinator.shared.alert(title: "Failed to move file!", body: "Make sure that your paths are correct and that you have access. Check error logs for more detailed information.")
                    }
                }
                .disabled(
                    !isAirliftCompatibilityMode()
                        ? imprtData.isEmpty
                        : (!isAcc || imprtData.isEmpty || airliftOperationRunning)
                )

                Button("Delete File", role: .destructive) {
                    if isAirliftCompatibilityMode() {
                        confirmAirliftDelete()
                        return
                    }
                    do {
                        let targetURL = URL(fileURLWithPath: "\(directory)/\(fileName)")
                        try fm.removeItem(at: targetURL)
                        print("(ov) successfully deleted file: \(targetURL.path)")
                        Haptic.shared.play(.heavy)
                    } catch {
                        print("(ov) failed to delete: \(error.localizedDescription)")
                        Alertinator.shared.alert(title: "Failed to delete file!", body: "Make sure that your paths are correct and that you have access. Check error logs for more detailed information.")
                    }
                }
                .disabled(
                    !isAirliftCompatibilityMode()
                        ? imprtData.isEmpty
                        : (!isAcc || airliftOperationRunning)
                )
            } header: {
                HeaderLabel("Operations", symbol: "wrench.and.screwdriver")
            }
        }
        .navigationTitle("File Operations")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
        .confirmationDialog(
            "What are you reading?",
            isPresented: $showAirliftReadKindChooser,
            titleVisibility: .visible
        ) {
            Button("File") { grantAirliftAccess(kind: .file) }
            Button("Folder") { grantAirliftAccess(kind: .folder) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose the target type before Airlift starts reading.")
        }
    }

    private func remoteTargetPath() -> String {
        let parent = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if parent.isEmpty { return name }
        if name.isEmpty { return parent }
        return URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(name)
            .standardizedFileURL.path
    }

    private func resetTargetState() {
        isAcc = false
        airliftTargetKind = nil
        if let snapshot = airliftSnapshotURL {
            try? FileManager.default.removeItem(at: snapshot)
        }
        airliftSnapshotURL = nil
        imprtName = ""
        imprtData = Data()
    }

    private func grantAirliftAccess(kind: AirliftBridge.ReadKind) {
        let path = remoteTargetPath()
        airliftOperationRunning = true
        airlift.readRemotePathForFileOperations(path: path, kind: kind) { success, snapshotURL, detail in
            airliftOperationRunning = false
            guard success, let snapshotURL else {
                isAcc = false
                airliftTargetKind = nil
                Alertinator.shared.alert(
                    title: "Failed to get access to target!",
                    body: detail,
                    showCancel: false,
                    actionLabel: "OK",
                    action: {}
                )
                return
            }

            if let previousSnapshot = airliftSnapshotURL {
                try? FileManager.default.removeItem(at: previousSnapshot)
            }
            airliftSnapshotURL = snapshotURL
            airliftTargetKind = kind
            isAcc = true
            Haptic.shared.play(.soft)
        }
    }

    private func exportSavedAirliftSnapshot() {
        guard let snapshot = airliftSnapshotURL,
              FileManager.default.fileExists(atPath: snapshot.path) else {
            Alertinator.shared.alert(
                title: "Snapshot unavailable",
                body: "Grant Access again to read and save a new snapshot.",
                showCancel: false,
                actionLabel: "OK",
                action: {}
            )
            return
        }
        // Export uses the snapshot created by Grant Access; it does not trigger another read.
        presentShareSheet(with: snapshot)
    }

    private func overwriteAirliftTarget() {
        guard !imprtData.isEmpty else { return }
        let target = remoteTargetPath()
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion-file-operations-\(UUID().uuidString)-\(imprtName.isEmpty ? "imported.bin" : imprtName)")
        do {
            try imprtData.write(to: localURL, options: .atomic)
        } catch {
            Alertinator.shared.alert(title: "Import failed", body: error.localizedDescription)
            return
        }

        airliftOperationRunning = true
        Task { @MainActor in
            let success = await airlift.writeBack(localURL: localURL, remotePath: target, logFeature: "file-operations")
            try? FileManager.default.removeItem(at: localURL)
            airliftOperationRunning = false
            if success {
                Alertinator.shared.alert(title: "File overwritten", body: "Airlift reported a successful write to the exact target path.", showCancel: false, actionLabel: "OK", action: {})
                Haptic.shared.play(.soft)
            } else {
                Alertinator.shared.alert(title: "Failed to overwrite file", body: "Check Home → Logs for the Airlift File Operations result.")
            }
        }
    }

    private func moveAirliftFile() {
        guard !imprtData.isEmpty else { return }
        let directoryPath = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetPath = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent(imprtName.isEmpty ? "imported.bin" : imprtName).path
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion-file-operations-\(UUID().uuidString)-\(imprtName.isEmpty ? "imported.bin" : imprtName)")
        do {
            try imprtData.write(to: localURL, options: .atomic)
        } catch {
            Alertinator.shared.alert(title: "Import failed", body: error.localizedDescription)
            return
        }

        airliftOperationRunning = true
        Task { @MainActor in
            // Preserve the original operation: write the imported file into Directory under its original name.
            let success = await airlift.writeBack(localURL: localURL, remotePath: targetPath, logFeature: "file-operations")
            try? FileManager.default.removeItem(at: localURL)
            airliftOperationRunning = false
            if success {
                Alertinator.shared.alert(title: "File moved", body: "The imported file was written to \(targetPath). The source import remains on this device.", showCancel: false, actionLabel: "OK", action: {})
                Haptic.shared.play(.soft)
            } else {
                Alertinator.shared.alert(title: "Failed to move file", body: "Check Home → Logs for the Airlift File Operations result.")
            }
        }
    }

    private func confirmAirliftDelete() {
        Alertinator.shared.alert(
            title: "Delete remote target?",
            body: "This will delete the remote file or directory at the entered path. This cannot be undone.",
            actionLabel: "Delete",
            action: { deleteAirliftTarget() }
        )
    }

    private func deleteAirliftTarget() {
        let target = remoteTargetPath()
        airliftOperationRunning = true
        Task { @MainActor in
            let success = await airlift.removeRemotePath(target, logFeature: "file-operations")
            airliftOperationRunning = false
            if success {
                Alertinator.shared.alert(title: "Remote target deleted", body: target, showCancel: false, actionLabel: "OK", action: {})
                resetTargetState()
            } else {
                Alertinator.shared.alert(title: "Failed to delete remote target", body: "Check Home → Logs for the Airlift File Operations result.")
            }
        }
    }

    func handleImport(_ res: Result<URL, Error>) {
        switch res {
        case .success(let recURL):
            do {
                let stopAccess = recURL.startAccessingSecurityScopedResource()
                defer {
                    if stopAccess {
                        recURL.stopAccessingSecurityScopedResource()
                    }
                }

                imprtData = try Data(contentsOf: recURL)
                imprtName = recURL.lastPathComponent
                if isAirliftCompatibilityMode() {
                    AirliftBridge.shared.appendFeatureLog("file-operations", "Imported local file: \(imprtName) (\(imprtData.count) bytes)")
                }
            } catch {
                print("(ov) failed to import file: \(error.localizedDescription)")
                Alertinator.shared.alert(title: "Failed to import file!", body: "This file is likely invaild, corrupted, or inaccessible. Please try a different overwrite file.")
            }
        case .failure(let error):
            print("(ov) failed to import file: \(error.localizedDescription)")
            Alertinator.shared.alert(title: "Failed to import file!", body: "This file is likely invaild, corrupted, or inaccessible. Please try a different overwrite file.")
        }
    }
}
