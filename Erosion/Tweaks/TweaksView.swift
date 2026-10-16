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
        NavigationStack {
            List {
                Section {
                    if airliftUIAccessRequired() && !airliftAccessReady {
                        blockedFeatureRow("Custom Wallpapers")
                        blockedFeatureRow("Dialer Themer")
                    } else {
                        NavigationLink("Custom Wallpapers", destination: PosterBoardView())
                        NavigationLink("Dialer Themer", destination: KeypadView())
                    }
                } header: {
                    HeaderLabel("Theming", symbol: "paintbrush")
                }
                
                if !isAirliftCompatibilityMode() {
                    Section {
                        if raveSupported() || weOnADebugBuild {
                            NavigationLink("MobileGestalt", destination: GestaltView())
                            NavigationLink("Advanced Key Editor", destination: AdvancedKeyEditorView())
                            NavigationLink("Config Tweaks", destination: ConfigView())
                        }
                        NavigationLink("File Operations", destination: OperationsView())
                    } header: {
                        HeaderLabel("System", symbol: "gear")
                    }
                }


                Section {
                    NavigationLink("Airlift", destination: AirliftView())

                    if airliftUIAccessRequired() && !airliftAccessReady {
                        blockedFeatureRow("Custom Passcode")
                        blockedFeatureRow("Cards Override")
                    } else {
                        NavigationLink("Custom Passcode", destination: ExperimentalPasscodeView())
                        NavigationLink("Cards Override", destination: ExperimentalWalletView())
                    }
                } header: {
                    HeaderLabel("Experimental", symbol: "flask")
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

    private var airliftAccessReady: Bool {
        airlift.airliftFeatureReady()
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
