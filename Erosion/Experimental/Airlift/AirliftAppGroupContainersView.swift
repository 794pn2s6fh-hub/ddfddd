import SwiftUI

struct AirliftAppGroupContainersView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var search = ""

    private var rows: [(label: String, path: String)] {
        var values: [(label: String, path: String)] = airlift.installedAppGroups.map { group in
            (label: group.groupIDs.first ?? "Group identifier unavailable", path: group.container)
        }
        values += airlift.appGroupAfcContainerPaths.map { (label: airlift.appGroupDisplayName(for: $0.container), path: $0.container) }
        values += airlift.appGroupContainerPaths.map { (label: airlift.appGroupDisplayName(for: $0.container), path: $0.container) }
        var seen = Set<String>(); values = values.filter { seen.insert($0.path).inserted }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.path.lowercased().contains(q) }.sorted { $0.label < $1.label }
    }

    var body: some View {
        List {
            Section {
                TextField("Search bundle ID or path…", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack { Text("Results"); Spacer(); Text("\(rows.count)/\(totalCount)").foregroundStyle(.secondary) }
            } header: { Label("Find a group", systemImage: "magnifyingglass") }
            Section {
                if rows.isEmpty { ContentUnavailableView("No matching containers", systemImage: "person.2") }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.label).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(row.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
            } header: { Label("App Group Containers", systemImage: "person.2") }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("bad_query").font(.headline)
                    Text(airlift.appGroupBadQueryScanLog.isEmpty ? "bad_query scan has not completed yet." : airlift.appGroupBadQueryScanLog.joined(separator: "\n"))
                    Text("AFC").font(.headline)
                    Text(airlift.appGroupAfcScanLog.isEmpty ? "AFC listing has not completed yet." : airlift.appGroupAfcScanLog.joined(separator: "\n"))
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            } header: { Label("Automatic Scan Log", systemImage: "terminal") }
        }
        .listStyle(.insetGrouped).navigationTitle("App Group Containers").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            airlift.scanInstalledAppContainers()
            airlift.scanAppGroupContainerPathsViaAirlift()
            airlift.scanAppGroupContainerPaths(maxInode: 500_000)
        }
    }
    private var totalCount: Int {
        Set(airlift.installedAppGroups.map(\.container) + airlift.appGroupAfcContainerPaths.map(\.container) + airlift.appGroupContainerPaths.map(\.container)).count
    }
}
import SwiftUI

enum AirliftSpecialContainerKind: Equatable {
    case internalDaemon, pluginKitPlugin
    var title: String { self == .internalDaemon ? "InternalDaemon" : "PluginKitPlugin" }
    var root: String { "/var/mobile/Containers/Data/\(title)" }
}

struct AirliftSpecialContainerView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    let kind: AirliftSpecialContainerKind
    @State private var search = ""
    @State private var resolvedBundleIDs: [String: String] = [:]
    @State private var bundleIDResolutionStarted: Set<String> = []
    @State private var bundleIDLookupResults: [String: FolderLabelDiagnostic] = [:]
    @State private var bundleIDResolutionLog: [String] = []

    private var metadataPaths: [AirliftAdditionalContainerPath] {
        kind == .internalDaemon ? airlift.installationProxyInternalDaemonPaths : airlift.installationProxyPluginKitPluginPaths
    }
    private var afcPaths: [String] {
        kind == .internalDaemon ? airlift.internalDaemonAfcPaths : airlift.pluginKitPluginAfcPaths
    }
    private var badQueryPaths: [String] {
        kind == .internalDaemon ? airlift.internalDaemonBadQueryPaths : airlift.pluginKitPluginBadQueryPaths
    }
    private var allContainerPaths: [String] {
        Array(Set(metadataPaths.map(\.path) + afcPaths + badQueryPaths)).sorted()
    }
    // Include InstallationProxy's sourceApps values, not just path names. The app scan
    // can finish after BadQuery has already listed the same paths.
    private var pathsSignature: String {
        let pathPart = allContainerPaths.joined(separator: "\n")
        let metadataPart = metadataPaths.map {
            "\(normalizedPath($0.path))=>\($0.sourceApps.sorted().joined(separator: ","))"
        }.sorted().joined(separator: "\n")
        return pathPart + "\n--installation-proxy-metadata--\n" + metadataPart
    }

    private func normalizedPath(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private func displayBundleID(for path: String) -> String {
        let normalized = normalizedPath(path)
        let leaf = URL(fileURLWithPath: normalized).lastPathComponent

        // Prefer the container's own MCMMetadataIdentifier. InstallationProxy's
        // sourceApps is often the parent application ID, which can differ from a
        // PluginKit extension's own identifier.
        if let resolved = resolvedBundleIDs[normalized], !resolved.isEmpty,
           UUID(uuidString: resolved) == nil {
            return resolved
        }

        // InstallationProxy can report the same physical container under a different
        // /var alias, so retain the existing exact-path and same-root leaf fallbacks.
        if let metadata = metadataPaths.first(where: { normalizedPath($0.path) == normalized }),
           let sourceApp = metadata.sourceApps.first(where: { !$0.isEmpty }) {
            return sourceApp
        }

        let rootToken = kind == .internalDaemon ? "/InternalDaemon/" : "/PluginKitPlugin/"
        if let metadata = metadataPaths.first(where: {
            let candidate = normalizedPath($0.path)
            return candidate.contains(rootToken) && URL(fileURLWithPath: candidate).lastPathComponent == leaf
        }), let sourceApp = metadata.sourceApps.first(where: { !$0.isEmpty }) {
            return sourceApp
        }

        return "Bundle identifier unavailable"
    }

    private var rows: [(label: String, path: String)] {
        let values = allContainerPaths.map { (label: displayBundleID(for: $0), path: $0) }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values.filter { q.isEmpty || $0.label.lowercased().contains(q) || $0.path.lowercased().contains(q) }
            .sorted { $0.label == $1.label ? $0.path < $1.path : $0.label < $1.label }
    }

    private var afcLog: [String] { airlift.additionalContainerAfcLog(for: kind.root) }
    private var badQueryLog: [String] { airlift.additionalContainerBadQueryLog(for: kind.root) }

    var body: some View {
        List {
            Section {
                TextField("Search bundle ID or path…", text: $search).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack { Text("Results"); Spacer(); Text("\(rows.count)/\(allContainerPaths.count)").foregroundStyle(.secondary) }
            } header: { Label("Find a container", systemImage: "magnifyingglass") }
            Section {
                if rows.isEmpty {
                    ContentUnavailableView("No matching containers", systemImage: "shippingbox")
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.label).font(.system(size: 13, weight: .medium, design: .monospaced))
                        Text(row.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
            } header: { Label(kind.title, systemImage: "shippingbox") }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bundle ID Resolution").font(.headline)
                    ScrollView {
                        Text(bundleIDResolutionLog.isEmpty
                             ? "Bundle ID diagnostics have not completed yet."
                             : bundleIDResolutionLog.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 210)

                    Text("bad_query").font(.headline)
                    Text(badQueryLog.isEmpty ? "bad_query scan has not completed yet." : badQueryLog.joined(separator: "\n"))
                    Text("AFC").font(.headline)
                    Text(afcLog.isEmpty ? "AFC listing has not completed yet." : afcLog.joined(separator: "\n"))
                }
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
            } header: { Label("Automatic Scan Log", systemImage: "terminal") }
        }
        .listStyle(.insetGrouped).navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
        .onAppear {
            airlift.scanInstalledAppContainers()
            airlift.probeAdditionalContainerRootViaAirlift(kind.root)
            airlift.scanAdditionalContainerRootWithBadQuery(kind.root, maxInode: 500_000)
            resolveBundleIdentifiersForPaths()
        }
        .onChange(of: pathsSignature) { _, _ in resolveBundleIdentifiersForPaths() }
    }

    /// Resolves the container's own MCM identifier and records how it compares with
    /// InstallationProxy's sourceApps mapping. This is metadata-only and never writes.
    private func resolveBundleIdentifiersForPaths() {
        var pending: [(key: String, path: String)] = []
        for path in allContainerPaths {
            let key = normalizedPath(path)
            guard bundleIDLookupResults[key] == nil,
                  !bundleIDResolutionStarted.contains(key) else { continue }
            bundleIDResolutionStarted.insert(key)
            pending.append((key, path))
        }

        guard !pending.isEmpty else {
            updateBundleIDResolutionLog()
            return
        }
        updateBundleIDResolutionLog()

        DispatchQueue.global(qos: .utility).async {
            var results: [String: FolderLabelDiagnostic] = [:]
            for item in pending {
                results[item.key] = diagnoseFolderLabel(url: URL(fileURLWithPath: item.path))
            }

            DispatchQueue.main.async {
                for (path, result) in results {
                    self.bundleIDLookupResults[path] = result
                    if let rawIdentifier = result.identifier {
                        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !identifier.isEmpty, UUID(uuidString: identifier) == nil {
                            self.resolvedBundleIDs[path] = identifier
                        }
                    }
                }
                self.updateBundleIDResolutionLog()
            }
        }
    }

    /// Rebuild the diagnostic output against the latest InstallationProxy data.
    /// This is important when InstallationProxy returns after BadQuery and adds
    /// sourceApps for paths which were already discovered by another scanner.
    private func updateBundleIDResolutionLog() {
        let metadataSnapshot = metadataPaths.map {
            (path: normalizedPath($0.path), sourceApps: $0.sourceApps)
        }
        let rootToken = kind == .internalDaemon ? "/InternalDaemon/" : "/PluginKitPlugin/"
        var lines: [String] = []
        var mcmIdentifierCount = 0
        var exactSourceAppCount = 0
        var leafSourceAppCount = 0
        var unresolvedCount = 0

        for path in allContainerPaths {
            let key = normalizedPath(path)
            let leaf = URL(fileURLWithPath: key).lastPathComponent
            let exactApps = Array(Set(metadataSnapshot.filter { $0.path == key }.flatMap { $0.sourceApps })).sorted()
            let leafApps = Array(Set(metadataSnapshot.filter {
                $0.path.contains(rootToken) && URL(fileURLWithPath: $0.path).lastPathComponent == leaf
            }.flatMap { $0.sourceApps })).sorted()
            let lookup = bundleIDLookupResults[key]
            let identifier = lookup?.identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let identifier, !identifier.isEmpty { mcmIdentifierCount += 1 }
            if !exactApps.isEmpty { exactSourceAppCount += 1 }
            else if !leafApps.isEmpty { leafSourceAppCount += 1 }

            let usableIdentifier = identifier.flatMap { value -> String? in
                guard !value.isEmpty, UUID(uuidString: value) == nil else { return nil }
                return value
            }
            let fallback = exactApps.first ?? leafApps.first ?? "Bundle identifier unavailable"
            let displayValue = usableIdentifier ?? fallback
            if displayValue == "Bundle identifier unavailable" { unresolvedCount += 1 }

            let mcmValue: String
            if let identifier, !identifier.isEmpty {
                mcmValue = UUID(uuidString: identifier) == nil ? identifier : "\(identifier) (UUID-shaped; not used as Bundle ID)"
            } else {
                mcmValue = lookup == nil ? "pending" : "unavailable"
            }
            let exactText = exactApps.isEmpty ? "none" : exactApps.joined(separator: ",")
            let leafText = leafApps.isEmpty ? "none" : leafApps.joined(separator: ",")
            let detail = lookup?.detail ?? (bundleIDResolutionStarted.contains(key) ? "metadata lookup pending" : "not scheduled")
            lines.append("[bundle-id] path=\(path) | MCMMetadataIdentifier=\(mcmValue) | lookup=\(detail) | InstallationProxy exact sourceApps=[\(exactText)] | same-root leaf sourceApps=[\(leafText)] | displayed=\(displayValue)")
        }

        let summary = "[bundle-id] SUMMARY: paths=\(allContainerPaths.count), MCM identifier(s) found=\(mcmIdentifierCount), exact InstallationProxy sourceApps matches=\(exactSourceAppCount), same-root leaf-only matches=\(leafSourceAppCount), unresolved=\(unresolvedCount)"
        bundleIDResolutionLog = [summary] + lines
    }

    private var totalCount: Int { allContainerPaths.count }
}
