//
//  PosterBoardView.swift
//  Erosion
//
//  Created by lunginspector on 8/19/26.
//

import SwiftUI

import UniformTypeIdentifiers

let pbHandler = PBHandler()

enum PBMsg {
    static var noTendies = "Import some tendies to start applying custom wallpapers."
    static var tooManyTendies = "You can only set a maximum of 15 wallpapers at a time. De-select another wallpaper pack if you'd like to apply this one!"
    static var limitWarning = "You have more than five wallpapers set. This may cause some wallpapers to not show up properly. Are you still sure that you'd like to apply these wallpapers?"
    static var corruption = "Please ensure that none of your wallpapers are corrupted, and try again."
    static var finishApply = "PosterBoard will open once you continue. Please kill it from the App Switcher. If no wallpapers show up, try resetting Collections, MercuryPoster, or Videos in the settings."
    static var applyInfo = "If no wallpapers appear inside of PosterBoard, reset Collections in settings and try again."
    static var imprtFailed = "Ensure that you've selected a vaild wallpaper file and try again."
}

struct PosterBoardView: View {
    @AppStorage("pbContainerPath") private var pbContainerPath = ""
    @AppStorage("tendiesArray") private var tendiesArray: [TendiesObject] = []
    @AppStorage("hasShownFirstRunMsg") private var hasShownFirstRunMsg = false
    
    @State private var showImporter = false
    @State private var airliftApplying = false
    let columns = Array(repeating: GridItem(.flexible()), count: device.userInterfaceIdiom == .pad ? 4 : 2)
    
    var body: some View {
        ScrollView {
            if tendiesArray.isEmpty {
                Button {
                    showImporter = true
                } label: {
                    VStack(alignment: .leading) {
                        CompactAlert(title: "No tendies imported!", symbol: "exclamationmark.triangle.fill", text: PBMsg.noTendies)
                            .padding(.horizontal, 15)
                    }
                    .frame(alignment: .leading)
                    .multilineTextAlignment(.leading)
                }
            }
            LazyVGrid(columns: columns) {
                ForEach($tendiesArray) { $tendies in
                    Button {
                        if !tendies.isOn && tendiesArray.filter({ $0.isOn }).flatMap({ $0.descrNames }).count > 15 {
                            Alertinator.shared.alert(title: "Max wallpaper limit reached!", body: PBMsg.tooManyTendies)
                        } else {
                            tendies.isOn.toggle()
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: tendies.targetDescr == .photos ? "play.rectangle" : "photo")
                                .imageScale(.large)
                                .foregroundStyle(Color.accentColor)
                            VStack {
                                Text(tendies.name)
                                    .lineLimit(1)
                                    .fontWeight(.medium)
                                Text("\(tendies.descrNames.count) wallpaper" + (tendies.descrNames.count == 1 ? "" : "s"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                        .padding(.vertical, 10)
                        .background {
                            if tendies.targetDescr == .mercury {
                                VStack {
                                    Text("M")
                                        .font(.footnote)
                                        .padding(6)
                                        .background(Color.accentColor)
                                        .clipShape(.circle)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .frame(maxHeight: .infinity)
                                .padding(12)
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 26)
                                .fill(Color(.secondarySystemBackground))
                                .overlay {
                                    if tendies.isOn {
                                        RoundedRectangle(cornerRadius: 26)
                                            .fill(Color.clear)
                                            .strokeBorder(lineWidth: 2)
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                        }
                        .contextMenu {
                            Button {
                                let url = AppURL.pbFolders.appendingPathComponent(tendies.folderName)
                                fsHandlers.openInFilesApp(url)
                            } label: {
                                Label("Show Data Folder", systemImage: "folder")
                            }
                            
                            Button(role: .destructive) {
                                withAnimation {
                                    let url = AppURL.pbFolders.appendingPathComponent(tendies.folderName)
                                    try? fm.removeItem(at: url)
                                    tendiesArray.removeAll { $0.id == tendies.id }
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 15)
            .foregroundStyle(Color(.label))
        }
        .navigationTitle("Wallpapers")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            doSetupStuff()
        }
        .safeAreaInset(edge: .bottom) {
            VStack {
                Button {
                    showImporter = true
                } label: {
                    ButtonLabel("Import .tendies", symbol: "arrow.down.doc")
                }
            }
            .buttonStyle(ActionButtonStyle())
            .frame(maxWidth: .infinity)
            .padding(device.userInterfaceIdiom == .pad ? 0 : 15)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import .tendies", systemImage: "arrow.down.doc")
                    }
                    
                    Button {
                        openApp(withBID: SysBID.poster)
                    } label: {
                        Label("Open PosterBoard", systemImage: "arrow.up.right.square")
                    }
                    
                    Divider()
                    
                    NavigationLink {
                        List {
                            Section {
                                TextField("PosterBoard Path", text: $pbContainerPath, axis: .vertical)
                                Button("Fetch Path") {
                                    pbContainerPath = fsHandlers.getContainerPath(forMatch: "com.apple.PosterBoard")
                                }
                            } header: {
                                HeaderLabel("PosterBoard", symbol: "photo")
                            }
                            
                            Section {
                                Button("Clear Imports") {
                                    for object in tendiesArray {
                                        let url = AppURL.pbFolders.appendingPathComponent(object.folderName)
                                        try? fm.removeItem(at: url)
                                    }
                                    tendiesArray.removeAll()
                                }
                                Button("Reset Collections", role: .destructive) {
                                    let res = resetWallpapers(for: PBPath.wpKit)
                                    if res {
                                        Haptic.shared.play(.soft)
                                    }
                                }
                                Button("Reset MercuryPoster", role: .destructive) {
                                    let res = resetWallpapers(for: PBPath.mercury)
                                    if res {
                                        Haptic.shared.play(.soft)
                                    }
                                }
                                Button("Reset Videos", role: .destructive) {
                                    let res = resetWallpapers(for: PBPath.photos)
                                    if res {
                                        Haptic.shared.play(.soft)
                                    }
                                }
                            } header: {
                                HeaderLabel("Data", symbol: "loupe")
                            } footer: {
                                Text("If you're having trouble applying custom wallpapers, try resetting any of the three extensions listed.")
                            }
                        }
                        .navigationTitle("PosterBoard Settings")
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button("Apply", role: .adaptiveConfirm) {
                    if !hasShownFirstRunMsg {
                        Alertinator.shared.alert(title: "Before you begin...", body: PBMsg.applyInfo, actionLabel: "Continue", action: {
                            hasShownFirstRunMsg = true
                            proceed()
                        })
                    } else if tendiesArray.filter({ $0.isOn }).flatMap({ $0.descrNames }).count > 5 {
                        Alertinator.shared.alert(title: "Before you begin...", body: PBMsg.limitWarning, actionLabel: "Confirm", action: {
                            proceed()
                        })
                    } else {
                        proceed()
                    }
                    
                    @MainActor
                    func proceed() {
                        let selected = tendiesArray.filter { $0.isOn }

                        // The five known iOS 27 builds keep the original BedQuery path.
                        // Other iOS 27 builds use the already-paired Airlift backend.
                        if isAirliftCompatibilityMode() {
                            guard AirliftBridge.shared.hasPairing() else {
                                Alertinator.shared.alert(
                                    title: "Airlift pairing required",
                                    body: "Pair Airlift first, then return here and apply the wallpapers again.",
                                    showCancel: false,
                                    actionLabel: "Ok",
                        action: {}
                                )
                                return
                            }

                            airliftApplying = true
                            Task { @MainActor in
                                do {
                                    try await AirliftPosterBoardWriter.shared.apply(
                                        objects: selected,
                                        pairingPath: AirliftBridge.shared.pairingFilePath()
                                    )
                                    airliftApplying = false
                                    Haptic.shared.play(.soft)
                                    Alertinator.shared.alert(
                                        title: "Wallpapers applied!",
                                        body: "Airlift injected the selected wallpapers. Open PosterBoard and close it to refresh the wallpaper list.",
                                        showCancel: false,
                                        actionLabel: "Ok",
                        action: {}
                                    )
                                } catch {
                                    airliftApplying = false
                                    Alertinator.shared.alert(
                                        title: "Failed to apply wallpapers!",
                                        body: error.localizedDescription,
                                        showCancel: false,
                                        actionLabel: "Ok",
                        action: {}
                                    )
                                }
                            }
                            return
                        }

                        let res = applyObjects(selected)
                        if !res.0 {
                            if res.1.contains("an item with the same name already exists") {
                                Alertinator.shared.alert(title: "Failed to apply wallpapers!", body: "Some of the wallpapers you selected have already been added.")
                            } else {
                                Alertinator.shared.alert(title: "Failed to apply wallpapers!", body: PBMsg.corruption)
                            }
                        } else {
                            Haptic.shared.play(.soft)
                            Alertinator.shared.alert(title: "Restart PosterBoard to finish applying!", body: PBMsg.finishApply, showCancel: false, actionLabel: "Continue", action: { openApp(withBID: SysBID.poster) })
                        }
                    }
                }
                .disabled(tendiesArray.filter({ $0.isOn }).isEmpty)
                .disabled(!fm.fileExists(atPath: AppURL.pb.path))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            let res = handleImport(result)
            if !res {
                Alertinator.shared.alert(title: "Failed to import .tendies!", body: PBMsg.imprtFailed)
            }
        }
    }
    
    private func doSetupStuff() {
        if pbContainerPath.isEmpty {
            pbContainerPath = fsHandlers.getContainerPath(forMatch: "com.apple.PosterBoard")
        }
        if !fm.fileExists(atPath: AppURL.pb.path) {
            do {
                try fm.createDirIfNeeded(at: AppURL.pb)
                try fm.createDirIfNeeded(at: AppURL.pbFolders)
            } catch {
                Alertinator.shared.alert(title: "Failed to setup PosterBoard tweaks!", body: AppMsg.opFailed)
            }
        }
    }
    
    private func applyObjects(_ objects: [TendiesObject]) -> (Bool, String) {
        let descrTargets = Set(objects.map(\.targetDescr))
        for descrTarget in descrTargets {
            let target = "\(pbContainerPath)/\(descrTarget.path)"
            let res = bq.grantAccess(atPath: target)
            if !res.0 {
                print("(mg) failed to grant access at \(target): \(res.2)")
                return (false, res.2)
            }
        }
        
        for object in objects {
            let container = "\(pbContainerPath)/\(object.targetDescr.path)"
            for descr in object.descrNames {
                let descrURL = AppURL.pbFolders.appendingPathComponent(object.folderName).appendingPathComponent(descr)
                let target = object.targetDescr == .mercury ? URL(fileURLWithPath: container).appendingPathComponent(descrURL.lastPathComponent) : URL(fileURLWithPath: container).appendingPathComponent(UUID().uuidString)
                do {
                    try fm.copyItem(at: descrURL, to: target)
                } catch {
                    print("(mg) failed to copy descriptor (folder: \(object.folderName)): \(error.localizedDescription)")
                    return (false, error.localizedDescription)
                }
            }
        }
        return (true, "")
    }
    
    private func resetWallpapers(for item: PBPath) -> Bool {
        do {
            let target = URL(fileURLWithPath: "\(pbContainerPath)/\(item.path)")
            let contents = try fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            
            for url in contents {
                try fm.removeItem(at: url)
            }
            return true
        } catch {
            print("(pb) failed to reset \(item.rawValue): \(error.localizedDescription)")
            return false
        }
    }
    
    private func handleImport(_ result: Result<URL, Error>) -> Bool {
        switch result {
        case .success(let fileURL):
            let stopAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if stopAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            if let tendies = pbHandler.makeObjectFromTendies(at: fileURL) {
                withAnimation {
                    tendiesArray.append(tendies)
                }
            }
            return true
        case .failure(let error):
            print("(pb) failed to import file: \(error.localizedDescription)")
            return false
        }
    }
}



// MARK: - Airlift PosterBoard backend

/// Airlift counterpart of the existing BedQuery wallpaper writer.
/// The PosterBoard UI and .tendies importer remain unchanged; only the
/// device-side write path changes on unsupported iOS 27 builds.
final class AirliftPosterBoardWriter {
    static let shared = AirliftPosterBoardWriter()
    private init() {}

    func apply(objects: [TendiesObject], pairingPath: String) async throws {
        guard !objects.isEmpty else {
            throw NSError(domain: "Erosion", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: PBMsg.noTendies])
        }

        let container = try await findPosterBoardContainer(pairingPath: pairingPath)
        print("[airlift-pb] PosterBoard container: \(container)")

        for object in objects {
            let extensionID: String
            switch object.targetDescr {
            case .wpKit:
                extensionID = "com.apple.WallpaperKit.CollectionsPoster"
            case .mercury:
                extensionID = "com.apple.MercuryPoster"
            case .photos:
                extensionID = "com.apple.PhotosUIPrivate.PhotosPosterProvider"
            }

            let parent = "\(container)/Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/\(extensionID)/descriptors"

            for descriptorName in object.descrNames {
                let importedSource = AppURL.pbFolders
                    .appendingPathComponent(object.folderName)
                    .appendingPathComponent(descriptorName)

                guard FileManager.default.fileExists(atPath: importedSource.path) else {
                    throw NSError(domain: "Erosion", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                                "Missing imported descriptor: \(descriptorName)"])
                }

                // Match AirCard's flash-time handling: do not depend on an
                // externally supplied PosterBoard hash/UUID. Generate the
                // descriptor destination UUID and wallpaper identifier here.
                let flashUUID = UUID().uuidString.uppercased()
                let flashID = Int.random(in: 10000...99999)

                let stageRoot = FileManager.default.temporaryDirectory
                    .appendingPathComponent("erosion-pb-descriptor-\(UUID().uuidString)", isDirectory: true)
                let stagedDescriptor = stageRoot.appendingPathComponent(flashUUID, isDirectory: true)
                try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: stageRoot) }
                try FileManager.default.copyItem(at: importedSource, to: stagedDescriptor)

                randomizePosterDescriptorIDs(in: stagedDescriptor, id: flashID)

                print("[airlift-pb] Flash descriptor \(flashUUID) (ID \(flashID))")

                try await injectFolder(
                    pairingPath: pairingPath,
                    source: stagedDescriptor.path,
                    targetParent: parent,
                    destination: flashUUID
                )

                // Newer Collections builds may read the migrated app extension.
                if object.targetDescr == .wpKit {
                    let modernParent = "\(container)/Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.Posters.CollectionsPosterApp/descriptors"
                    try? await injectFolder(
                        pairingPath: pairingPath,
                        source: stagedDescriptor.path,
                        targetParent: modernParent,
                        destination: flashUUID
                    )
                }
            }
        }

        try await writePosterBoardPreferences(pairingPath: pairingPath, container: container)

        // Do not respring here. PosterBoard should be refreshed by opening
        // and closing it, matching the original Erosion behavior.
        print("[airlift-pb] Wallpaper injection complete; no respring requested")
    }

    private func findPosterBoardContainer(pairingPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outContainer: UnsafeMutablePointer<CChar>?
                var outError: UnsafeMutablePointer<CChar>?

                let rc = pairingPath.withCString { pairC in
                    "com.apple.PosterBoard".withCString { bundleC in
                        al_find_app_container(
                            pairC, bundleC, nil, nil,
                            &outContainer, &outError
                        )
                    }
                }

                if rc == 0, let ptr = outContainer {
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    continuation.resume(returning: value)
                    return
                }

                let error = outError.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                } ?? "Failed to find PosterBoard container"

                continuation.resume(throwing: NSError(
                    domain: "AirliftPosterBoard",
                    code: Int(rc),
                    userInfo: [NSLocalizedDescriptionKey: error]
                ))
            }
        }
    }

    private func injectFolder(
        pairingPath: String,
        source: String,
        targetParent: String,
        destination: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>?

                let rc = pairingPath.withCString { pairC in
                    source.withCString { sourceC in
                        targetParent.withCString { parentC in
                            destination.withCString { destC in
                                al_exploit_inject_folder(
                                    pairC,
                                    sourceC,
                                    parentC,
                                    destC,
                                    { _, msg in
                                        if let msg {
                                            print("[airlift-pb] \(String(cString: msg))")
                                        }
                                    },
                                    nil,
                                    &outError
                                )
                            }
                        }
                    }
                }

                if rc == 0 {
                    continuation.resume()
                    return
                }

                let error = outError.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                } ?? "Airlift folder injection failed"

                continuation.resume(throwing: NSError(
                    domain: "AirliftPosterBoard",
                    code: Int(rc),
                    userInfo: [NSLocalizedDescriptionKey: error]
                ))
            }
        }
    }

    private func randomizePosterDescriptorIDs(in descriptorURL: URL, id: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: descriptorURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }

            switch fileURL.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try? String(id).data(using: .utf8)?.write(to: fileURL)

            case "com.apple.posterkit.provider.contents.userInfo", "Wallpaper.plist":
                guard let data = try? Data(contentsOf: fileURL),
                      var plist = try? PropertyListSerialization.propertyList(
                        from: data, options: .mutableContainers, format: nil
                      ) as? [String: Any] else { continue }

                if fileURL.lastPathComponent == "com.apple.posterkit.provider.contents.userInfo" {
                    plist["wallpaperRepresentingIdentifier"] = id
                } else {
                    plist["identifier"] = id
                }

                if let updated = try? PropertyListSerialization.data(
                    fromPropertyList: plist, format: .binary, options: 0
                ) {
                    try? updated.write(to: fileURL)
                }

            default:
                break
            }
        }
    }

    private func writePosterBoardPreferences(pairingPath: String, container: String) async throws {
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("erosion-pb-pref-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }

        let prefURL = stage.appendingPathComponent(
            "com.apple.PosterBoard.unprotectedUserDefaults.plist"
        )

        let prefs: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": false,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster"
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
            ]
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: prefs,
            format: .binary,
            options: 0
        )
        try data.write(to: prefURL)

        try await writeDirectory(
            pairingPath: pairingPath,
            source: stage.path,
            target: "\(container)/Library/Preferences"
        )

        try? await writeDirectory(
            pairingPath: pairingPath,
            source: stage.path,
            target: "/var/mobile/Library/Preferences"
        )
    }

    private func writeDirectory(
        pairingPath: String,
        source: String,
        target: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>?

                let rc = pairingPath.withCString { pairC in
                    source.withCString { sourceC in
                        target.withCString { targetC in
                            al_exploit_write_dir(
                                pairC,
                                sourceC,
                                targetC,
                                { _, msg in
                                    if let msg {
                                        print("[airlift-pb] \(String(cString: msg))")
                                    }
                                },
                                nil,
                                &outError
                            )
                        }
                    }
                }

                if rc == 0 {
                    continuation.resume()
                    return
                }

                let error = outError.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                } ?? "Airlift directory write failed"

                continuation.resume(throwing: NSError(
                    domain: "AirliftPosterBoard",
                    code: Int(rc),
                    userInfo: [NSLocalizedDescriptionKey: error]
                ))
            }
        }
    }


}
