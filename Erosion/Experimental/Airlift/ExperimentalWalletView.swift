import SwiftUI

struct ExperimentalWalletView: View {
    @StateObject private var walletCards = WalletCardSkinManager()
    @State private var showImagePicker = false

    var body: some View {
        Group {
            if airliftUIAccessRequired() && !(AirliftBridge.shared.airliftFeatureReady()) {
                ContentUnavailableView("Airlift required", systemImage: "link.circle", description: Text("Enable LocalDevVPN and import a valid pairing file in Airlift."))
            } else {
                List {
            Section {
                HStack {
                    Image(systemName: "creditcard.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cards Override")
                        Text("Detect a Wallet card, choose artwork, and overwrite its local card-face cache.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        if walletCards.isScanning { walletCards.stopScanning() } else { walletCards.startScanning() }
                    } label: {
                        Label(walletCards.isScanning ? "Stop Scan" : "Scan Cards", systemImage: walletCards.isScanning ? "stop.circle.fill" : "wave.3.left.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(walletCards.isScanning ? .red : .orange)
                    Spacer()
                    Button("Select All") { walletCards.selectAll() }.disabled(walletCards.cardIDs.isEmpty)
                }
                HStack {
                    TextField("Card hash / identifier", text: $walletCards.manualCardID)
                        .font(.system(size: 12, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add") { walletCards.addManualCard() }
                        .disabled(walletCards.manualCardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if !walletCards.cardIDs.isEmpty {
                    ForEach(walletCards.cardIDs, id: \.self) { id in
                        Button { walletCards.toggleSelected(id) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: walletCards.selectedCardIDs.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(walletCards.selectedCardIDs.contains(id) ? .orange : .secondary)
                                Text(id).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                Spacer()
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if !walletCards.scanStatus.isEmpty {
                    Text(walletCards.scanStatus).font(.caption).foregroundStyle(.secondary)
                }
                if let data = walletCards.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill().frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).clipped()
                        .overlay(alignment: .topTrailing) {
                            Button { walletCards.clearImage() } label: {
                                Image(systemName: "xmark.circle.fill").font(.title2).symbolRenderingMode(.hierarchical).foregroundStyle(.white)
                            }.padding(8)
                        }
                }
                Button { showImagePicker = true } label: {
                    Label(walletCards.imageData == nil ? "Choose Card Artwork" : "Replace Card Artwork", systemImage: "photo.on.rectangle")
                }
                Button { walletCards.applySelectedCards() } label: {
                    HStack {
                        Text(walletCards.flashRunning ? "Overwriting…" : "Overwrite Apple Pay Cards")
                        Spacer()
                        if walletCards.flashRunning { ProgressView() } else { Image(systemName: "arrow.down.circle.fill") }
                    }
                }.disabled(!walletCards.canApply)
            } header: {
                Label("Cards Override", systemImage: "creditcard")
            } footer: {
                Text("Artwork only: this targets the Wallet card-face assets and does not change payment credentials.")
            }
            if !walletCards.flashLog.isEmpty {
                Section("Log") {
                    ScrollView {
                        Text(walletCards.flashLog.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 220)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Cards Override")
        .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showImagePicker) {
                    ImagePickerView { data in walletCards.setImageData(data) }
                }
            }
        }
    }
}
