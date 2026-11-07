import SwiftUI
import Combine
import UIKit
import ImageIO
import AVFoundation
import CryptoKit

/// Keeps remote Explore previews on disk and in memory so revisiting either
/// gallery does not request the same preview again.
private actor HomeThemingPreviewCache {
    static let shared = HomeThemingPreviewCache()

    private let imageMemory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 192 * 1024 * 1024
        return cache
    }()

    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ErosionThemingPreviews", isDirectory: true)
    }

    func image(for remoteURL: URL) async throws -> UIImage {
        let key = remoteURL.absoluteString as NSString
        if let cached = imageMemory.object(forKey: key) {
            return cached
        }

        let fileURL = try await cachedFile(for: remoteURL)
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard let image = Self.decodeImage(data, fileExtension: remoteURL.pathExtension.lowercased()) else {
            throw URLError(.cannotDecodeContentData)
        }
        imageMemory.setObject(image, forKey: key)
        return image
    }

    func cachedFile(for remoteURL: URL) async throws -> URL {
        let fileURL = cacheURL(for: remoteURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        return fileURL
    }

    private func cacheURL(for remoteURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        let ext = remoteURL.pathExtension.lowercased()
        let safeExtension = ext.isEmpty ? "preview" : ext
        return cacheDirectory.appendingPathComponent(filename).appendingPathExtension(safeExtension)
    }

    private static func decodeImage(_ data: Data, fileExtension: String) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let frameCount = CGImageSourceGetCount(source)
        if fileExtension == "gif", frameCount > 1 {
            let maxFrames = 48
            let strideValue = max(1, Int(ceil(Double(frameCount) / Double(maxFrames))))
            let thumbnailOptions: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
            ] as CFDictionary

            var frames: [UIImage] = []
            var duration: TimeInterval = 0

            for index in stride(from: 0, to: frameCount, by: strideValue) {
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions) else {
                    continue
                }

                frames.append(UIImage(cgImage: cgImage))
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as NSDictionary?
                let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? NSDictionary
                let unclampedDelay = gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber
                let clampedDelay = gifProperties?[kCGImagePropertyGIFDelayTime] as? NSNumber
                let frameDelay = max(0.04, (unclampedDelay ?? clampedDelay)?.doubleValue ?? 0.1)
                duration += frameDelay * Double(strideValue)
            }

            if !frames.isEmpty {
                return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
            }
        }

        let thumbnailOptions: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200
        ] as CFDictionary
        if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) {
            return UIImage(cgImage: thumbnail)
        }
        return UIImage(data: data)
    }
}

@MainActor
private final class HomeThemingPreviewLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var videoURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false

    private var loadedURL: String?

    func load(_ remoteURL: URL?) async {
        guard let remoteURL else {
            image = nil
            videoURL = nil
            failed = false
            loadedURL = nil
            return
        }

        let key = remoteURL.absoluteString
        guard loadedURL != key else { return }
        loadedURL = key
        image = nil
        videoURL = nil
        failed = false
        isLoading = true
        defer { isLoading = false }

        do {
            let ext = remoteURL.pathExtension.lowercased()
            if ["mp4", "mov", "m4v"].contains(ext) {
                videoURL = try await HomeThemingPreviewCache.shared.cachedFile(for: remoteURL)
            } else {
                image = try await HomeThemingPreviewCache.shared.image(for: remoteURL)
            }
        } catch {
            failed = true
        }
    }
}

struct HomeThemingCachedPreview: View {
    enum Scaling {
        case fit
        case fill
    }

    let url: URL?
    var scaling: Scaling = .fit

    @StateObject private var loader = HomeThemingPreviewLoader()

    private var uiImageContentMode: UIView.ContentMode {
        scaling == .fill ? .scaleAspectFill : .scaleAspectFit
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let videoURL = loader.videoURL {
                    HomeThemingLoopingVideo(url: videoURL, scaling: scaling)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let image = loader.image {
                    HomeThemingAnimatedImage(image: image, contentMode: uiImageContentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if loader.failed {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Keep the original centered preview loading indicator.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipped()
        .task(id: url?.absoluteString) {
            await loader.load(url)
        }
    }
}

private final class HomeThemingPreviewImageView: UIImageView {
    // Do not let the downloaded image's pixel dimensions participate in
    // SwiftUI's parent layout. The parent preview frame owns the size.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}

private struct HomeThemingAnimatedImage: UIViewRepresentable {
    let image: UIImage
    let contentMode: UIView.ContentMode

    func makeUIView(context: Context) -> HomeThemingPreviewImageView {
        let view = HomeThemingPreviewImageView()
        view.contentMode = contentMode
        view.clipsToBounds = true
        view.backgroundColor = .clear
        view.image = image
        if image.images != nil { view.startAnimating() }
        return view
    }

    func updateUIView(_ view: HomeThemingPreviewImageView, context: Context) {
        view.contentMode = contentMode
        if view.image !== image {
            view.image = image
            if image.images != nil {
                view.startAnimating()
            } else {
                view.stopAnimating()
            }
        }
    }
}

private final class HomeThemingVideoContainer: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct HomeThemingLoopingVideo: UIViewRepresentable {
    let url: URL
    let scaling: HomeThemingCachedPreview.Scaling

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> HomeThemingVideoContainer {
        let view = HomeThemingVideoContainer()
        let player = AVQueuePlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: url)
        context.coordinator.player = player
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        view.playerLayer.player = player
        view.playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
        player.play()
        return view
    }

    func updateUIView(_ view: HomeThemingVideoContainer, context: Context) {
        view.playerLayer.videoGravity = scaling == .fill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ view: HomeThemingVideoContainer, coordinator: Coordinator) {
        coordinator.player?.pause()
        view.playerLayer.player = nil
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
    }
}
