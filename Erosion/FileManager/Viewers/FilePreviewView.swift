import SwiftUI
import AVKit
import QuickLook
import UIKit

/// In-app preview for common media and binary assets in a File Browser snapshot.
/// The viewer is read-only: it never mutates the selected file.
struct FilePreviewView: View {
    let url: URL
    let remotePath: String?
    let remoteWritable: Bool
    @Environment(\.dismiss) private var dismiss

    init(url: URL, remotePath: String? = nil, remoteWritable: Bool = false) {
        self.url = url
        self.remotePath = remotePath
        self.remoteWritable = remoteWritable
    }

    private var ext: String { url.pathExtension.lowercased() }
    private var isImage: Bool {
        ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp"].contains(ext)
    }
    private var isVideo: Bool {
        ["mp4", "mov", "m4v"].contains(ext)
    }
    private var isAudio: Bool {
        ["mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "aac"].contains(ext)
    }
    private var isBinary: Bool {
        ["dylib", "bin", "so", "o"].contains(ext)
    }

    var body: some View {
        Group {
            if isImage {
                ImagePreview(url: url, remotePath: remotePath, remoteWritable: remoteWritable)
            } else if isVideo {
                VideoFilePreview(url: url)
            } else if isAudio {
                AudioFilePreview(url: url)
            } else if isBinary {
                BinaryFilePreview(url: url, remotePath: remotePath)
            } else {
                QuickLookAirliftFallback(url: url)
            }
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") { dismiss() }
            }
        }
    }
}

private struct ImagePreview: View {
    let url: URL
    let remotePath: String?
    let remoteWritable: Bool
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var image: UIImage?
    @State private var status = ""
    @State private var showResize = false
    @State private var widthText = ""
    @State private var heightText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: "%.1f×", Double(scale)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Spacer()
                if remoteWritable {
                    Button("Resize") {
                        guard let image else { return }
                        widthText = String(Int(image.size.width * image.scale))
                        heightText = String(Int(image.size.height * image.scale))
                        showResize = true
                    }
                    .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            GeometryReader { proxy in
                ZStack {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .contentShape(Rectangle())
                            .gesture(
                                SimultaneousGesture(
                                    MagnificationGesture()
                                        .onChanged { value in scale = min(max(committedScale * value, 0.25), 8) }
                                        .onEnded { _ in committedScale = scale },
                                    DragGesture()
                                        .onChanged { value in offset = CGSize(width: committedOffset.width + value.translation.width, height: committedOffset.height + value.translation.height) }
                                        .onEnded { _ in committedOffset = offset }
                                )
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scale = 1; committedScale = 1; offset = .zero; committedOffset = .zero
                                }
                            }
                    } else {
                        ContentUnavailableView("Unable to Open Image", systemImage: "photo", description: Text(url.lastPathComponent))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }

            HStack {
                if let image {
                    Text("\(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale))")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                } else {
                    Text("—")
                }
                Spacer()
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.black.opacity(0.04))
        .task(id: url) { image = UIImage(contentsOfFile: url.path) }
        .alert("Resize image", isPresented: $showResize) {
            TextField("Width", text: $widthText).keyboardType(.numberPad)
            TextField("Height", text: $heightText).keyboardType(.numberPad)
            Button("Apply") { resizeImage() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the new pixel dimensions.")
        }
    }

    private func resizeImage() {
        guard let currentImage = image, let w = Int(widthText), let h = Int(heightText), w > 0, h > 0 else { return }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h))
        let resized = renderer.image { _ in currentImage.draw(in: CGRect(x: 0, y: 0, width: w, height: h)) }
        let data: Data?
        switch url.pathExtension.lowercased() {
        case "png": data = resized.pngData()
        default: data = resized.jpegData(compressionQuality: 1.0)
        }
        guard let data else { status = "Encode failed"; return }
        do {
            try data.write(to: url, options: .atomic)
            // Avoid shadowing the @State property with `guard let image`.
            image = UIImage(data: data)
            status = "Saved locally"
            if let remotePath {
                Task {
                    let ok = await AirliftBridge.shared.writeBack(localURL: url, remotePath: remotePath)
                    await MainActor.run { status = ok ? "Written to device" : "Remote write failed" }
                }
            }
        } catch { status = "Write failed: \(error.localizedDescription)" }
    }
}

private struct VideoFilePreview: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onDisappear {
                        player.pause()
                    }
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
        }
    }
}

private struct AudioFilePreview: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            Text(url.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal)

            if let player {
                HStack(spacing: 28) {
                    Button {
                        if isPlaying {
                            player.pause()
                        } else {
                            player.play()
                        }
                        isPlaying.toggle()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.seek(to: .zero)
                        isPlaying = false
                    } label: {
                        Image(systemName: "backward.end.circle")
                            .font(.system(size: 38))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView()
            }

            Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .task(id: url) {
            player = AVPlayer(url: url)
            isPlaying = false
        }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
    }

    private var fileSize: Int64 {
        Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
    }
}

private struct BinaryFilePreview: View {
    let url: URL
    let remotePath: String?
    @State private var showInfo = false

    var body: some View {
        HexDumpView(url: url)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Info")
                }
            }
            .sheet(isPresented: $showInfo) {
                BinaryInfoViewer(url: url)
            }
    }
}

private struct BinaryInfoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    private var info: BinaryFileInfo {
        BinaryFileInfo(url: url)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 24, weight: .semibold))

                    VStack(alignment: .leading, spacing: 8) {
                        InfoLine(label: "Mach-O", value: info.machODescription)
                        InfoLine(label: "Architecture", value: info.architecture)
                        InfoLine(label: "File type", value: info.fileType)
                        InfoLine(label: "Load commands", value: info.loadCommands)
                        InfoLine(label: "Load command bytes", value: info.loadCommandBytes)
                        InfoLine(label: "Flags", value: info.flags)
                        InfoLine(label: "File size", value: info.fileSize)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private struct InfoLine: View {
        let label: String
        let value: String

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 17, design: .monospaced))
            }
        }
    }
}

private struct BinaryFileInfo {
    let machODescription: String
    let architecture: String
    let fileType: String
    let loadCommands: String
    let loadCommandBytes: String
    let flags: String
    let fileSize: String

    init(url: URL) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        fileSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)

        guard let data = try? Data(contentsOf: url), data.count >= 4 else {
            machODescription = "Not a Mach-O file"
            architecture = "Unknown"
            fileType = "Unknown"
            loadCommands = "—"
            loadCommandBytes = "—"
            flags = "—"
            return
        }

        let magic = Self.u32(data, at: 0, bigEndian: false)
        let bigMagic = Self.u32(data, at: 0, bigEndian: true)
        var offset = 0
        var bigEndian = false
        var is64 = false

        if magic == 0xFEEDFACF {
            is64 = true
        } else if magic == 0xFEEDFACE {
            is64 = false
        } else if bigMagic == 0xFEEDFACF {
            is64 = true
            bigEndian = true
        } else if bigMagic == 0xFEEDFACE {
            is64 = false
            bigEndian = true
        } else if magic == 0xCAFEBABE || bigMagic == 0xCAFEBABE {
            // FAT Mach-O: inspect the first architecture entry.
            bigEndian = true
            let count = Self.u32(data, at: 4, bigEndian: true)
            if count > 0, data.count >= 20 {
                let cputype = Self.u32(data, at: 8, bigEndian: true)
                let archOffset = Self.u32(data, at: 16, bigEndian: true)
                architecture = Self.cpuName(cputype)
                machODescription = "Universal Mach-O"
                fileType = "Universal binary"
                loadCommands = "—"
                loadCommandBytes = "—"
                flags = "—"
                _ = archOffset
                return
            }
            machODescription = "Universal Mach-O"
            architecture = "Unknown"
            fileType = "Universal binary"
            loadCommands = "—"
            loadCommandBytes = "—"
            flags = "—"
            return
        } else {
            machODescription = "Not a Mach-O file"
            architecture = "Unknown"
            fileType = "Unknown"
            loadCommands = "—"
            loadCommandBytes = "—"
            flags = "—"
            return
        }

        let cputype = Self.u32(data, at: offset + 4, bigEndian: bigEndian)
        let type = Self.u32(data, at: offset + 12, bigEndian: bigEndian)
        let ncmds = Self.u32(data, at: offset + (is64 ? 16 : 16), bigEndian: bigEndian)
        let sizeofcmds = Self.u32(data, at: offset + (is64 ? 20 : 20), bigEndian: bigEndian)
        let flagsValue = Self.u32(data, at: offset + (is64 ? 24 : 24), bigEndian: bigEndian)

        machODescription = is64 ? "64-bit" : "32-bit"
        architecture = Self.cpuName(cputype)
        fileType = Self.fileTypeName(type)
        loadCommands = "\(ncmds)"
        loadCommandBytes = "\(sizeofcmds)"
        flags = String(format: "0x%08X", flagsValue)
    }

    private static func u32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func cpuName(_ cputype: UInt32) -> String {
        switch cputype {
        case 0x0100000C: return "ARM64"
        case 0x0200000C: return "ARM64_32"
        case 0x0000000C: return "ARM"
        case 0x01000007: return "X86_64"
        case 0x00000007: return "X86"
        case 0x01000012: return "ARM64E"
        default: return String(format: "CPU 0x%08X", cputype)
        }
    }

    private static func fileTypeName(_ type: UInt32) -> String {
        switch type {
        case 1: return "Relocatable object"
        case 2: return "Executable"
        case 3: return "Fixed VM shared library"
        case 4: return "Core"
        case 5: return "Preloaded executable"
        case 6: return "Dynamic library"
        case 7: return "Dynamic linker"
        case 8: return "Bundle"
        case 9: return "Dynamic library stub"
        case 10: return "DWARF debug"
        case 11: return "Kext bundle"
        default: return String(format: "Type %u", type)
        }
    }
}

private struct HexDumpView: View {
    let url: URL
    private let maxBytes = 1_048_576

    @State private var data = Data()
    @State private var totalBytes = 0
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { geometry in
            // Each displayed byte takes about four monospaced characters across
            // the hex and ASCII columns. Adapt the bytes-per-row to the viewport
            // so the viewer never needs horizontal scrolling.
            let characterCapacity = Int(max(0, geometry.size.width - 12) / 6)
            let bytesPerLine = max(4, min(32, (characterCapacity - 12) / 4))

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Offset    Hex bytes       ASCII")
                        .font(.system(size: 10, design: .monospaced))
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()
                        .padding(.horizontal, 6)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else if isLoading {
                        ProgressView("Loading…")
                            .padding(24)
                    } else if data.isEmpty {
                        Text("File is empty.")
                            .font(.system(size: 12, design: .monospaced))
                            .padding(24)
                    } else {
                        ForEach(Array(stride(from: 0, to: data.count, by: bytesPerLine)), id: \.self) { offset in
                            HexLineView(
                                offset: offset,
                                bytes: Array(data[offset..<min(offset + bytesPerLine, data.count)]),
                                bytesPerLine: bytesPerLine
                            )
                        }

                        if totalBytes > maxBytes {
                            Text("… truncated at 1 MiB (total \(totalBytes) bytes)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color(.systemBackground))
        .task(id: url) {
            load()
        }
    }

    private func load() {
        errorMessage = nil
        isLoading = true
        data = Data()
        totalBytes = 0

        do {
            let fileData = try Data(contentsOf: url)
            totalBytes = fileData.count
            data = Data(fileData.prefix(maxBytes))
        } catch {
            errorMessage = "Unable to read file: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

private struct HexLineView: View {
    let offset: Int
    let bytes: [UInt8]
    let bytesPerLine: Int

    var body: some View {
        Text(renderedLine)
            .font(.system(size: 10, design: .monospaced))
            .textSelection(.enabled)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedLine: String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        let paddedHex = hex.padding(toLength: max(0, bytesPerLine * 3 - 1), withPad: " ", startingAt: 0)
        let ascii = bytes.map { byte -> Character in
            (byte >= 0x20 && byte < 0x7F) ? Character(UnicodeScalar(byte)) : "."
        }
        return String(format: "%08X  %@  %@", offset, paddedHex, String(ascii))
    }
}

private struct QuickLookAirliftFallback: View {
    let url: URL
    @State private var previewURL: URL?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
            Text(url.lastPathComponent)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button {
                previewURL = url
            } label: {
                Label("Preview", systemImage: "eye")
            }
        }
        .padding()
        .quickLookPreview($previewURL)
        .onAppear {
            previewURL = url
        }
    }
}

