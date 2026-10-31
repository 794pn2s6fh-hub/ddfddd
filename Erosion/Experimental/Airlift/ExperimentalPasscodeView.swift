import SwiftUI
import UniformTypeIdentifiers

/// Transfers immutable preview images from the worker task to SwiftUI without
/// decoding the entire theme again on the main thread.
private final class PasscodePreviewImageBox: @unchecked Sendable {
    let images: [String: UIImage]
    init(_ images: [String: UIImage]) { self.images = images }
}

struct ExperimentalPasscodeView: View {
    @EnvironmentObject private var airlift: AirliftBridge
    @State private var showImporter = false
    @State private var selectedDigit: String?
    @State private var showImagePicker = false
    @AppStorage("erosion.passcode.keySizeRaw") private var keySizeRaw = KPSize.defSize.rawValue
    @AppStorage("erosion.passcode.customWidth") private var custW = 0
    @AppStorage("erosion.passcode.customHeight") private var custH = 0
    @AppStorage("erosion.passcode.maskKeys") private var maskKeys = false
    @State private var showSizeAlert = false
    @State private var awaitingApplyResult = false
    @State private var processedPreviewImages: [String: UIImage] = [:]

    private let digits = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["", "0", ""]]

    private var keySize: KPSize {
        KPSize(rawValue: keySizeRaw) ?? .defSize
    }

    private var keySizeBinding: Binding<KPSize> {
        Binding(
            get: { KPSize(rawValue: keySizeRaw) ?? .defSize },
            set: { keySizeRaw = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView(.vertical) {
                    VStack(spacing: 18) {
                        themeSections
                        keySizePicker
                        keypadPreview
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .task(id: previewConfigurationKey) {
                    await rebuildPreviewImages()
                }
                .navigationTitle("Custom Passcode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showImporter = true
                            } label: {
                                Label("Import .passthm", systemImage: "square.and.arrow.down")
                            }

                            Button {
                                maskKeys = true
                                Haptic.shared.play(.soft)
                            } label: {
                                Label("Mask Keys", systemImage: "circle")
                            }

                            Button {
                                airlift.getCurrentPasscodeKeys()
                            } label: {
                                Label("Get Current Keys", systemImage: "externaldrive")
                            }
                            .disabled(airlift.passcodeFlashRunning || airlift.readRunning)

                            Divider()

                            Button {
                                keySizeRaw = KPSize.defSize.rawValue
                                custW = 0
                                custH = 0
                                maskKeys = false
                                airlift.clearPasscodeKeys()
                                Haptic.shared.play(.soft)
                            } label: {
                                Label("Clear Keys", systemImage: "xmark")
                            }
                            .disabled(airlift.passcodeFlashRunning)

                            Button(role: .destructive) {
                                Alertinator.shared.alert(
                                    title: "Are you sure you'd like to reset your passcode keys?",
                                    body: "This removes the current contents of /var/mobile/Library/Caches/TelephonyUI-10 on the device. Your selected theme remains available to apply again.",
                                    actionLabel: "Confirm",
                                    action: {
                                        keySizeRaw = KPSize.defSize.rawValue
                                        custW = 0
                                        custH = 0
                                        maskKeys = false
                                        Task {
                                            let succeeded = await airlift.resetPasscodeKeys()
                                            if succeeded {
                                                Alertinator.shared.alert(
                                                    title: "Successfully reset passcode keys!",
                                                    body: "Passcode keys were reset."
                                                )
                                            } else {
                                                Alertinator.shared.alert(
                                                    title: "Failed to reset passcode keys!",
                                                    body: AppMsg.opFailed
                                                )
                                            }
                                        }
                                    }
                                )
                            } label: {
                                Label("Reset Keys", systemImage: "trash")
                            }
                            .disabled(airlift.passcodeFlashRunning)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Apply", role: .adaptiveConfirm) {
                            awaitingApplyResult = true
                            airlift.flashPasscodeTheme(
                                keySize: keySize,
                                customWidth: custW,
                                customHeight: custH,
                                maskKeys: maskKeys
                            )
                        }
                        .disabled(airlift.passcodeFlashRunning || airlift.passcodeTheme == nil)
                    }
                }
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.archive, UTType(filenameExtension: "passthm") ?? .data], allowsMultipleSelection: false) { result in
                    guard case .success(let urls) = result, let url = urls.first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }
                    // Preserve the original Import .passthm behavior: load the chosen theme
                    // directly onto the keypad. This is separate from Explore's Library import.
                    if airlift.loadPasscodeTheme(url: url) {
                        PasscodeThemeLibraryStore.shared.clearSelection()
                    }
                }
                .sheet(isPresented: $showImagePicker) {
                    ImagePickerView { data in
                        guard let digit = selectedDigit, let image = UIImage(data: data) else { return }
                        airlift.setPasscodeKeyImage(digit: digit, image: image, data: data)
                    }
                }
                .onChange(of: airlift.passcodeFlashRunning) { wasRunning, isRunning in
                    guard awaitingApplyResult, wasRunning, !isRunning else { return }
                    awaitingApplyResult = false

                    let succeeded = airlift.passcodeLastApplySucceeded == true
                    if succeeded {
                        Alertinator.shared.alert(
                            title: "Successfully applied custom passcode keys!",
                            body: "Lock your device to see the new passcode artwork."
                        )
                        Haptic.shared.play(.soft)
                    } else {
                        Alertinator.shared.alert(
                            title: "Failed to apply custom passcode keys!",
                            body: AppMsg.opFailed
                        )
                    }
                }
    }

    private var keySizePicker: some View {
        VStack(spacing: 2) {
            Text("Key Size")
            Picker("", selection: keySizeBinding) {
                ForEach(KPSize.allCases, id: \.self) { size in
                    Text(size.label + (size == .custom ? " (\(custW)x\(custH))" : "")).tag(size)
                }
            }
            .alert("What would you like the custom size to be?", isPresented: $showSizeAlert) {
                TextField("Width", value: $custW, format: .number)
                    .keyboardType(.numberPad)
                TextField("Height", value: $custH, format: .number)
                    .keyboardType(.numberPad)
                Button("Cancel", role: .cancel) {
                    keySizeRaw = KPSize.defSize.rawValue
                }
                Button("Set") {
                    maskKeys = false
                }
            }
            .onChange(of: keySizeRaw) { _, rawValue in
                let newSize = KPSize(rawValue: rawValue) ?? .defSize
                if newSize == .custom {
                    showSizeAlert = true
                } else {
                    maskKeys = false
                }
            }
            .pickerStyle(.menu)
        }
        .padding(6)
        .background(Color(.systemBackground), in: .rect(cornerRadius: cornerRad.component))
    }

    private var themeSections: some View {
        VStack(spacing: 0) {
            NavigationLink {
                PasscodeExploreView()
            } label: {
                themeSectionRow("Explore")
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color(.separator).opacity(0.9))
                .frame(height: 1.15)
                .padding(.leading, 16)
                .padding(.trailing, 16)

            NavigationLink {
                PasscodeLibraryView()
            } label: {
                themeSectionRow("Library")
            }
            .buttonStyle(.plain)
        }
        .background(
            Color(.secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: cornerRad.platter, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRad.platter, style: .continuous))
    }

    private func themeSectionRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(Color(.label))
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    private var keypadPreview: some View {
        let allDigits = digits.flatMap { $0 }
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 16
        ) {
            ForEach(Array(allDigits.enumerated()), id: \.offset) { _, digit in
                if digit.isEmpty {
                    Color.clear.frame(width: 80, height: 80)
                } else {
                    Button {
                        selectedDigit = digit
                        showImagePicker = true
                    } label: {
                        keypadKeyLabel(for: digit)
                    }
                    .frame(width: 80, height: 80)
                    .aspectRatio(1, contentMode: .fit)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose artwork for key \(digit)")
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: 325)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func keypadKeyLabel(for digit: String) -> some View {
        if let image = previewImage(for: digit) {
            // Default/unmasked previews use the already-decoded theme image.
            // Custom transformations use a cached image produced off the main thread.
            let denoVal: Float = isPad() ? 2.1 : 3.0
            Image(uiImage: image)
                .resizable()
                .frame(
                    width: CGFloat(Float(image.size.width) / denoVal),
                    height: CGFloat(Float(image.size.height) / denoVal)
                )
                .background {
                    Circle()
                        .fill(Color.clear)
                        .glassEffect(.clear, in: .circle)
                        .frame(width: 78, height: 78)
                }
        } else {
            let keypadID = KeypadID.allCases.first { $0.dialerNumber == digit }
            VStack(spacing: 1) {
                Text(digit)
                    .font(.system(size: 34, weight: .regular))
                if let letters = keypadID?.dialerLetters, !letters.isEmpty {
                    Text(letters)
                        .font(.system(size: 11, weight: .medium))
                        .tracking(1.5)
                }
            }
            .frame(width: 78, height: 78)
            .aspectRatio(1, contentMode: .fit)
            .foregroundStyle(Color(.label))
            .glassEffect(.clear.interactive(), in: .circle)
        }
    }

    private func previewImage(for digit: String) -> UIImage? {
        guard let theme = airlift.passcodeTheme else { return nil }
        // This is the normal state on first entry. Do not spawn a worker or decode
        // copies of ten full-resolution PNGs just to show an unchanged theme.
        if keySize == .defSize && !maskKeys {
            return theme.keys[digit]
        }
        return processedPreviewImages[digit] ?? theme.keys[digit]
    }

    private var previewConfigurationKey: String {
        let themeID = airlift.passcodeTheme?.id.uuidString ?? "no-theme"
        return "\(themeID)|\(keySizeRaw)|\(custW)|\(custH)|\(maskKeys)"
    }

    private func rebuildPreviewImages() async {
        // Avoid touching image data for the default/unmasked state. The original
        // theme's UIImage values are already cached in AirliftBridge.
        guard keySize != .defSize || maskKeys else {
            processedPreviewImages = [:]
            return
        }
        processedPreviewImages = [:]
        guard let theme = airlift.passcodeTheme else { return }

        // Theme readers and the image picker store rawData alongside every image.
        // Read only those bytes here; never encode UIImage on the main thread.
        var sourceData: [String: Data] = [:]
        for row in digits {
            for digit in row where !digit.isEmpty {
                if let data = theme.rawData[digit] {
                    sourceData[digit] = data
                }
            }
        }
        guard !sourceData.isEmpty else { return }

        let themeID = theme.id.uuidString
        let sizeRaw = keySizeRaw
        let width = custW
        let height = custH
        let shouldMask = maskKeys
        let worker = Task.detached(priority: .utility) { () -> PasscodePreviewImageBox in
            var images: [String: UIImage] = [:]
            let size = KPSize(rawValue: sizeRaw) ?? .defSize
            for (digit, data) in sourceData {
                if Task.isCancelled { break }
                let processedData: Data
                if size == .defSize && !shouldMask {
                    processedData = data
                } else {
                    processedData = processPasscodeKeyData(
                        data,
                        size: size,
                        customWidth: width,
                        customHeight: height,
                        mask: shouldMask
                    )
                }
                // UIImage decoding also stays on the worker thread. Returning the
                // immutable results in a box prevents large PNGs being decoded by
                // SwiftUI while it is laying out the keypad.
                if let image = UIImage(data: processedData) {
                    images[digit] = image
                }
            }
            return PasscodePreviewImageBox(images)
        }

        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled,
              previewConfigurationKey == "\(themeID)|\(sizeRaw)|\(width)|\(height)|\(shouldMask)" else { return }
        processedPreviewImages = result.images
    }


}
