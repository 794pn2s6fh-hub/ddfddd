//
//  FMRootView.swift
//  Erosion
//
//  Created by lunginspector on 8/26/26.
//

import SwiftUI

enum FSPaths {
    static let appContainers = "/var/mobile/Containers/Data/Application"
    static var appBundles = "/var/containers/Bundle/Application"
}

enum FSURL {
    static let appContainers = URL(fileURLWithPath: FSPaths.appContainers)
    static var sysGroup = URL(fileURLWithPath: "/var/containers/Shared/SystemGroup")
    static var configProfiles = FSURL.sysGroup.appendingPathComponent("systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles")
    static var internalDaemons = URL(fileURLWithPath: "/var/mobile/Containers/Data/InternalDaemon")
    static var appPlugins = URL(fileURLWithPath: "/var/mobile/Containers/Data/PluginKitPlugin")
    static var appGroup = URL(fileURLWithPath: "/var/mobile/Containers/Shared/AppGroup")
    static var systemData = URL(fileURLWithPath: "/var/containers/Data/System")
    static let stagedSystemApps = URL(fileURLWithPath: "/private/var/staged_system_apps")
    static let systemLibrary = URL(fileURLWithPath: "/System/Library")
    static let systemDeveloper = URL(fileURLWithPath: "/System/Developer")
    static let systemCryptexes = URL(fileURLWithPath: "/System/Cryptexes")
    static let usrLib = URL(fileURLWithPath: "/usr/lib")
    static let usrShare = URL(fileURLWithPath: "/usr/share")
    static let bin = URL(fileURLWithPath: "/bin")
    static let sbin = URL(fileURLWithPath: "/sbin")
    static let mobileLibrary = URL(fileURLWithPath: "/var/mobile/Library")
    static let mobileMedia = URL(fileURLWithPath: "/var/mobile/Media")
    static let etc = URL(fileURLWithPath: "/etc")
    static let cores = URL(fileURLWithPath: "/cores")
    static let tmp = URL(fileURLWithPath: "/tmp")
    static let varTmpHeard = URL(fileURLWithPath: "/var/tmp/com.apple.heard")
    static let findMy = URL(fileURLWithPath: "/Applications/FindMy.app")
    static let systemDriverKit = URL(fileURLWithPath: "/System/DriverKit")
    static let dev = URL(fileURLWithPath: "/dev")
}

struct FMRootView: View {
    @EnvironmentObject var mgr: ErosionManager

    var body: some View {
        NavigationStack {
            List {
                if !isAirliftCompatibilityMode() {
                    Section {
                        NavigationLink("Data Containers", destination: FileBrowserView(path: FSURL.appContainers, isContainer: true))
                        NavigationLink("Plugin Containers", destination: FileBrowserView(path: FSURL.appPlugins, isContainer: true))
                        NavigationLink("App Groups", destination: FileBrowserView(path: FSURL.appGroup, shouldGrant: true))
                    } header: {
                        HeaderLabel("Apps", symbol: "square.grid.2x2")
                    }
                    
                    Section {
                        NavigationLink("Daemon Containers", destination: FileBrowserView(path: FSURL.internalDaemons, isContainer: true))
                        NavigationLink("System Containers", destination: FileBrowserView(path: FSURL.systemData, shouldGrant: true))
                        NavigationLink("SystemGroup Containers", destination: FileBrowserView(path: FSURL.sysGroup, isContainer: true))
                    } header: {
                        HeaderLabel("System", symbol: "gear")
                    }
                }

                Section {
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.systemLibrary) {
                        NavigationLink("Library", destination: FileBrowserView(path: FSURL.systemLibrary, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.systemDeveloper) {
                        NavigationLink("DeveIoper", destination: FileBrowserView(path: FSURL.systemDeveloper, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.systemCryptexes) {
                        NavigationLink("Cryptexes", destination: FileBrowserView(path: FSURL.systemCryptexes, readOnly: true))
                    }
                } header: {
                    HeaderLabel("System Paths", symbol: "folder.badge.gearshape")
                } footer: {
                    Text("System paths are displayed read-only. File modifications are disabled.")
                }

                Section {
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.usrLib) {
                        NavigationLink("Lib", destination: FileBrowserView(path: FSURL.usrLib, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.usrShare) {
                        NavigationLink("Share", destination: FileBrowserView(path: FSURL.usrShare, readOnly: true))
                    }
                } header: {
                    HeaderLabel("Usr", symbol: "folder.badge.gearshape")
                } footer: {
                    Text("These paths are read-only.")
                }

                Section {
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.bin) {
                        NavigationLink("Bin", destination: FileBrowserView(path: FSURL.bin, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.stagedSystemApps) {
                        NavigationLink("Staged System Apps", destination: FileBrowserView(path: FSURL.stagedSystemApps, readOnly: true))
                    }
                    NavigationLink("Etc", destination: EtcBrowserView())
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.sbin) {
                        NavigationLink("Sbin", destination: FileBrowserView(path: FSURL.sbin, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.mobileLibrary) {
                        NavigationLink("Mobile Library", destination: FileBrowserView(path: FSURL.mobileLibrary, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.mobileMedia) {
                        NavigationLink("Mobile Media", destination: FileBrowserView(path: FSURL.mobileMedia, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.cores) {
                        NavigationLink("/cores", destination: FileBrowserView(path: FSURL.cores, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.tmp) {
                        NavigationLink("/tmp", destination: FileBrowserView(path: FSURL.tmp, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadPath(FSURL.varTmpHeard) {
                        if SystemReadOnlyAccess.isDirectory(FSURL.varTmpHeard) {
                            NavigationLink("com.apple.heard", destination: FileBrowserView(path: FSURL.varTmpHeard, readOnly: true))
                        } else {
                            NavigationLink("com.apple.heard", destination: SystemReadOnlyTextViewer(fileURL: FSURL.varTmpHeard))
                        }
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.findMy) {
                        NavigationLink("/Applications/FindMy.app", destination: FileBrowserView(path: FSURL.findMy, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.systemDriverKit) {
                        NavigationLink("/System/DriverKit", destination: FileBrowserView(path: FSURL.systemDriverKit, readOnly: true))
                    }
                    if SystemReadOnlyAccess.canReadDirectory(FSURL.dev) {
                        NavigationLink("/dev", destination: FileBrowserView(path: FSURL.dev, readOnly: true))
                    }
                } header: {
                    HeaderLabel("Other Paths", symbol: "folder")
                } footer: {
                    Text("Other stuff. Also read-only.")
                }
            }
            .navigationTitle("File Browser")
        }
    }
}


private struct EtcBrowserView: View {
    private let files: [URL] = [
        URL(fileURLWithPath: "/etc/hosts"),
        URL(fileURLWithPath: "/etc/passwd"),
        URL(fileURLWithPath: "/etc/services"),
        URL(fileURLWithPath: "/etc/protocols"),
        URL(fileURLWithPath: "/etc/group")
    ]

    var body: some View {
        FileBrowserView(
            path: FSURL.etc,
            readOnly: true,
            fixedFiles: files,
            navigationTitleOverride: "Etc"
        )
    }
}


private struct SystemReadOnlyTextViewer: View {
    let fileURL: URL
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle(fileURL.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Text("Read-only")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
        }
        .onAppear {
            text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? "Unable to read file."
        }
    }
}
