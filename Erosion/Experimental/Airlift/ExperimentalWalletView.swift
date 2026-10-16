import SwiftUI

struct ExperimentalWalletView: View {
    @StateObject private var walletCards = WalletCardSkinManager()
    @State private var showImagePicker = false
    @State private var showManualCardAlert = false
    @State private var manualHashDraft = ""
    @State private var panDragStarts: [String: CGSize] = [:]
    @State private var awaitingApplyResult = false

    var body: some View {
        Group {
            if airliftUIAccessRequired() && !AirliftBridge.shared.airliftFeatureReady() {
                ContentUnavailableView(
                    "Airlift required",
                    systemImage: "link.circle",
                    description: Text("Enable LocalDevVPN and import a valid pairing file in Airlift.")
                )
            } else {
                cardEditor
            }
        }
        .navigationTitle("Card Editor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button {
                            walletCards.getCurrentArtworks()
                        } label: {
                            Label("Get Current Artworks", systemImage: "externaldrive")
                        }
                        .disabled(walletCards.cardIDs.isEmpty || walletCards.isReadingArtworks || !AirliftBridge.shared.airliftFeatureReady())

                        Button {
                            manualHashDraft = ""
                            showManualCardAlert = true
                        } label: {
                            Label("Add Card by Hash", systemImage: "number")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            walletCards.clearScanResults()
                        } label: {
                            Label("Clear Scan Results", systemImage: "xmark")
                        }
                        .disabled(walletCards.cardIDs.isEmpty && !walletCards.isScanning)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button(walletCards.flashRunning ? "Applying…" : "Apply", role: .adaptiveConfirm) {
                    awaitingApplyResult = true
                    walletCards.applySelectedCards()
                }
                .disabled(!walletCards.canApply)
            }
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView { data in
                walletCards.setImageData(data)
            }
        }
        .alert("Add Card by Hash", isPresented: $showManualCardAlert) {
            TextField("Card hash / identifier", text: $manualHashDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { manualHashDraft = "" }
            Button("Add") {
                walletCards.manualCardID = manualHashDraft
                walletCards.addManualCard()
                manualHashDraft = ""
            }
        } message: {
            Text("Enter the card identifier, then choose Get Current Artworks from the menu.")
        }
        .onAppear {
            syncActiveCard()
        }
        .onChange(of: walletCards.flashRunning) { wasRunning, isRunning in
            guard awaitingApplyResult, wasRunning, !isRunning else { return }
            awaitingApplyResult = false

            if walletCards.lastApplySucceeded == true {
                Alertinator.shared.alert(
                    title: "Card artwork applied!",
                    body: "Apple Wallet card artwork was overwritten successfully.",
                    showCancel: false,
                    actionLabel: "OK",
                    action: {}
                )
                Haptic.shared.play(.soft)
            } else {
                Alertinator.shared.alert(
                    title: "Failed to apply card artwork!",
                    body: "One or more card images could not be overwritten. Check the Card Editor logs for details.",
                    showCancel: false,
                    actionLabel: "OK",
                    action: {}
                )
            }
        }
    }

    private var cardEditor: some View {
        GeometryReader { geometry in
            let cardWidth = min(max(geometry.size.width * 0.82, 250), 460)
            let cardHeight = cardWidth * 969.0 / 1536.0

            ScrollView(.vertical) {
                VStack(spacing: 20) {
                    overlayTypePicker

                    if walletCards.cardIDs.isEmpty {
                        ContentUnavailableView(
                            "No Cards Found",
                            systemImage: "creditcard",
                            description: Text("Scan Apple Pay to show your cards here.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                    } else {
                        ForEach(walletCards.cardIDs, id: \.self) { cardID in
                            VStack(spacing: 9) {
                                cardArtwork(for: cardID, width: cardWidth, height: cardHeight)
                                    .accessibilityLabel("Choose artwork for card \(cardID)")

                                Text(cardID)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                    .frame(maxWidth: cardWidth + 20)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    logs
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 15)
                .padding(.top, 8)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if walletCards.isScanning {
                    walletCards.stopScanning()
                } else {
                    walletCards.startScanning()
                }
            } label: {
                ButtonLabel(
                    walletCards.isScanning ? "Stop Scan" : "Scan Cards",
                    symbol: walletCards.isScanning ? "stop.circle.fill" : "viewfinder"
                )
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(!AirliftBridge.shared.airliftFeatureReady() && !walletCards.isScanning)
            .frame(maxWidth: .infinity)
            .padding(isPad() ? 0 : 15)
        }
    }

    private var overlayTypePicker: some View {
        VStack(spacing: 2) {
            Text("Overlay Type")
            Picker("", selection: $walletCards.overlayType) {
                ForEach(WalletCardOverlayType.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        }
        .padding(6)
        .background(Color(.systemBackground), in: .rect(cornerRadius: cornerRad.component))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func cardArtwork(for cardID: String, width: CGFloat, height: CGFloat) -> some View {
        let image = walletCards.displayedArtworkData(for: cardID).flatMap { UIImage(data: $0) }
        let isStretch = walletCards.overlayType == .stretch
        let sourceSize = image?.size ?? CGSize(width: width, height: height)
        let sourceAspect = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : width / height
        let viewportAspect = width / height
        let scaledSize: CGSize = {
            guard !isStretch, sourceSize.width > 0, sourceSize.height > 0 else {
                return CGSize(width: width, height: height)
            }
            if sourceAspect > viewportAspect {
                return CGSize(width: height * sourceAspect, height: height)
            }
            return CGSize(width: width, height: width / sourceAspect)
        }()
        let maxOffsetX = max(0, (scaledSize.width - width) / 2)
        let maxOffsetY = max(0, (scaledSize.height - height) / 2)
        let pan = walletCards.panPosition(for: cardID)

        let cardContents = Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: scaledSize.width, height: scaledSize.height)
                    .offset(
                        x: isStretch ? 0 : pan.width * maxOffsetX,
                        y: isStretch ? 0 : pan.height * maxOffsetY
                    )
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                    Image(systemName: "creditcard")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

        if !isStretch, image != nil, maxOffsetX > 0 || maxOffsetY > 0 {
            cardContents
                .onTapGesture {
                    walletCards.selectCard(cardID)
                    showImagePicker = true
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            if panDragStarts[cardID] == nil {
                                panDragStarts[cardID] = walletCards.panPosition(for: cardID)
                            }
                            guard let start = panDragStarts[cardID] else { return }
                            let next = CGSize(
                                width: start.width + (maxOffsetX > 0 ? value.translation.width / maxOffsetX : 0),
                                height: start.height + (maxOffsetY > 0 ? value.translation.height / maxOffsetY : 0)
                            )
                            walletCards.setPanPosition(next, for: cardID, persist: false)
                        }
                        .onEnded { _ in
                            if panDragStarts[cardID] != nil {
                                walletCards.setPanPosition(walletCards.panPosition(for: cardID), for: cardID, persist: true)
                            }
                            panDragStarts.removeValue(forKey: cardID)
                        }
                )
                .buttonStyle(.plain)
        } else {
            cardContents
                .onTapGesture {
                    walletCards.selectCard(cardID)
                    showImagePicker = true
                }
                .buttonStyle(.plain)
        }
    }

    private var logs: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeaderLabel("Logs", symbol: "apple.terminal")
                .foregroundStyle(.secondary)
                .padding(.leading, 18)

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: terminalRad, style: .continuous)
                        .fill(Color(.secondarySystemFill))

                    ScrollView(showsIndicators: false) {
                        Text(walletCards.flashLog.joined(separator: "\n"))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer()
                            .id(0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 14)
                }
                .frame(width: geometry.size.width, height: max(0, geometry.size.height - 28))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .modifier(TerminalPlatter())
            .contextMenu {
                Button {
                    Haptic.shared.play(.soft)
                    UIPasteboard.general.string = walletCards.flashLog.joined(separator: "\n")
                } label: {
                    Label("Copy Output", systemImage: "doc.on.doc")
                }

                Button {
                    do {
                        let formatter = DateFormatter()
                        formatter.dateFormat = "MM-dd-yyyy-HHmmss"
                        let date = formatter.string(from: Date())
                        let tempURL = URL.temporaryDirectory
                            .appendingPathComponent("Wallet-Log-\(date)")
                            .appendingPathExtension("txt")
                        let logData = Data(walletCards.flashLog.joined(separator: "\n").utf8)
                        try logData.write(to: tempURL)
                        presentShareSheet(with: tempURL)
                    } catch {
                        print("(wallet) failed to export logs: \(error.localizedDescription)")
                    }
                } label: {
                    Label("Export Logs", systemImage: "square.and.arrow.up")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func syncActiveCard() {
        if let activeCardID = walletCards.activeCardID,
           walletCards.cardIDs.contains(activeCardID) {
            walletCards.selectCard(activeCardID)
        } else if let firstCard = walletCards.cardIDs.first {
            walletCards.selectCard(firstCard)
        }
    }
}
