//
//  TweaksView.swift
//  Erosion
//
//  Created by lunginspector on 8/26/26.
//

import SwiftUI


struct TweaksView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var blockedFeature: String?

    var body: some View {
        let accessRequired = airliftUIAccessRequired()
        let accessReady = accessRequired ? airlift.airliftFeatureReady() : true
        NavigationStack {
            List {
                Section {
                    if accessRequired && !accessReady {
                        blockedFeatureRow("Custom Wallpapers")
                        blockedFeatureRow("Dialer Themer")
                    } else {
                        NavigationLink("Custom Wallpapers", destination: PosterBoardView())
                        NavigationLink("Dialer Themer", destination: KeypadView())
                    }
                } header: {
                    HeaderLabel("Theming", symbol: "paintbrush")
                }
                
                Section {
                    if !isAirliftCompatibilityMode() {
                        if raveSupported() || weOnADebugBuild {
                            NavigationLink("MobileGestalt", destination: GestaltView())
                            NavigationLink("Advanced Key Editor", destination: AdvancedKeyEditorView())
                            NavigationLink("Config Tweaks", destination: ConfigView())
                        }
                    }
                    if accessRequired && !accessReady {
                        blockedFeatureRow("File Operations")
                    } else {
                        NavigationLink("File Operations", destination: OperationsView())
                    }
                } header: {
                    HeaderLabel("System", symbol: "gear")
                }


                Section {
                    // Keep the access check at the navigation row rather than inside
                    // ExperimentalPasscodeView.body. This avoids repeated synchronous
                    // LocalDevVPN/pairing checks while SwiftUI builds the passcode screen.
                    if accessRequired && !accessReady {
                        blockedFeatureRow("Custom Passcode")
                    } else {
                        NavigationLink("Custom Passcode", destination: ExperimentalPasscodeView())
                    }

                    if accessRequired && !accessReady {
                        blockedFeatureRow("Cards Override")
                    } else {
                        NavigationLink("Cards Override", destination: ExperimentalWalletView())
                    }

                    if accessRequired && !accessReady {
                        blockedFeatureRow("Other")
                    } else {
                        NavigationLink("Other", destination: OtherView())
                    }
                } header: {
                    HeaderLabel("Airlift", symbol: "antenna.radiowaves.left.and.right")
                }
            }
            .navigationTitle("Tweaks")
            .alert("Airlift required", isPresented: Binding(get: { blockedFeature != nil }, set: { if !$0 { blockedFeature = nil } })) {
                Button("OK", role: .cancel) { blockedFeature = nil }
            } message: {
                Text("Enable LocalDevVPN and import a valid pairing file in Airlift before opening \(blockedFeature ?? "this feature").")
            }
        }
    }


    @ViewBuilder
    private func blockedFeatureRow(_ title: String) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        // Intentionally not a Button/NavigationLink: the row keeps the normal
        // Settings-style appearance but remains non-interactive until Airlift
        // access requirements are satisfied.
    }
}
