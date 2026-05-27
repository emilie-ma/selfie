import AVFoundation
import Photos
import UIKit

struct CapturedMedia: Identifiable, Codable {
    let id: UUID
    let filename: String
    let isVideo: Bool
    let createdAt: Date

    var fileURL: URL {
        MediaStorageService.mediaDirectory.appendingPathComponent(filename)
    }
}

enum SaveDestination {
    case appOnly
    case cameraRollOnly
    case both
}

enum VideoThumbnailGenerator {
    static func cgImage(from generator: AVAssetImageGenerator, at time: CMTime) -> CGImage? {
        if #available(iOS 18.0, *) {
            var result: CGImage?
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                defer { semaphore.signal() }
                result = try? await generator.image(at: time).0
            }
            semaphore.wait()
            return result
        } else {
            return try? generator.copyCGImage(at: time, actualTime: nil)
        }
    }
}

final class MediaStorageService {
    static let shared = MediaStorageService()

    static var mediaDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Selfies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let indexFile: URL

    private init() {
        indexFile = Self.mediaDirectory.appendingPathComponent("index.json")
    }

    func loadAll() -> [CapturedMedia] {
        guard
            let data = try? Data(contentsOf: indexFile),
            let items = try? JSONDecoder().decode([CapturedMedia].self, from: data)
        else { return [] }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func savePhoto(data: Data, destination: SaveDestination) async -> CapturedMedia? {
        let id = UUID()
        let filename = "\(id.uuidString).jpg"
        let url = Self.mediaDirectory.appendingPathComponent(filename)

        var savedMedia: CapturedMedia?

        if destination == .appOnly || destination == .both {
            do {
                try data.write(to: url)
                let media = CapturedMedia(id: id, filename: filename, isVideo: false, createdAt: Date())
                appendToIndex(media)
                savedMedia = media
            } catch {
                return nil
            }
        }

        if destination == .cameraRollOnly || destination == .both {
            let success = await savePhotoToCameraRoll(data: data)
            if destination == .cameraRollOnly && success {
                savedMedia = CapturedMedia(id: id, filename: filename, isVideo: false, createdAt: Date())
            }
        }

        return savedMedia
    }

    @discardableResult
    func saveVideo(from sourceURL: URL, destination: SaveDestination) async -> CapturedMedia? {
        let id = UUID()
        let filename = "\(id.uuidString).mov"
        let destURL = Self.mediaDirectory.appendingPathComponent(filename)

        var savedMedia: CapturedMedia?

        if destination == .appOnly || destination == .both {
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
                let media = CapturedMedia(id: id, filename: filename, isVideo: true, createdAt: Date())
                appendToIndex(media)
                savedMedia = media
            } catch {
                return nil
            }
        }

        if destination == .cameraRollOnly || destination == .both {
            let success = await saveVideoToCameraRoll(url: sourceURL)
            if destination == .cameraRollOnly && success {
                savedMedia = CapturedMedia(id: id, filename: filename, isVideo: true, createdAt: Date())
            }
        }

        try? FileManager.default.removeItem(at: sourceURL)
        return savedMedia
    }

    func thumbnail(for media: CapturedMedia, size: CGSize = CGSize(width: 200, height: 200)) -> UIImage? {
        if media.isVideo {
            let asset = AVURLAsset(url: media.fileURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = size
            guard let cgImage = VideoThumbnailGenerator.cgImage(from: generator, at: .zero) else { return nil }
            return UIImage(cgImage: cgImage)
        }
        guard let data = try? Data(contentsOf: media.fileURL),
              let image = UIImage(data: data) else { return nil }
        return image.preparingThumbnail(of: size)
    }

    static func gridThumbnailPixelSize() -> CGSize {
        let screenWidth = UIScreen.main.bounds.width
        let cellWidth = (screenWidth - 8) / 3
        let pixels = cellWidth * UIScreen.main.scale
        return CGSize(width: pixels, height: pixels)
    }

    func fullImage(for media: CapturedMedia) -> UIImage? {
        guard !media.isVideo,
              let data = try? Data(contentsOf: media.fileURL) else { return nil }
        return UIImage(data: data)
    }

    private func appendToIndex(_ media: CapturedMedia) {
        var items = loadAll()
        items.insert(media, at: 0)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: indexFile)
        }
    }

    private func savePhotoToCameraRoll(data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private func saveVideoToCameraRoll(url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}