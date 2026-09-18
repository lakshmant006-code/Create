import Foundation
import AVFoundation
import UIKit

/// Handles copying imported videos into the app's own sandbox, generating a
/// thumbnail for the project grid, and persisting the project list between
/// launches. Marked `@MainActor` for the same reason as VideoComposer —
/// `AVURLAsset(url:)` is main-actor isolated on newer SDKs.
@MainActor
enum ProjectStore {

    static let maxImportSizeBytes = 500 * 1024 * 1024 // 500 MB

    enum ImportError: LocalizedError {
        case fileTooLarge

        var errorDescription: String? {
            switch self {
            case .fileTooLarge:
                return "That video is larger than 500 MB. Trim it down or lower its resolution, then try again."
            }
        }
    }

    private static var videosDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "Videos")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var projectsFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "projects.json")
    }

    static func sourceURL(forFilename filename: String) -> URL {
        videosDirectory.appending(path: filename)
    }

    static func thumbnailURL(forFilename filename: String) -> URL {
        videosDirectory.appending(path: filename)
    }

    /// Copies a video the user just picked (Photos or Files) into the
    /// sandbox, generates a thumbnail, and creates a fresh project pointed
    /// at both. `temporaryURL` only needs to be valid for this call.
    /// Rejects anything over `maxImportSizeBytes` up front, before copying.
    static func importVideo(from temporaryURL: URL, name: String) async throws -> VideoProject {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path),
           let sizeInBytes = attributes[.size] as? Int,
           sizeInBytes > maxImportSizeBytes {
            throw ImportError.fileTooLarge
        }

        let ext = temporaryURL.pathExtension.isEmpty ? "mov" : temporaryURL.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = videosDirectory.appending(path: filename)
        try FileManager.default.copyItem(at: temporaryURL, to: destination)

        let asset = AVURLAsset(url: destination)
        let durationSeconds = try await asset.load(.duration).seconds

        var project = VideoProject(
            name: name,
            sourceFilename: filename,
            duration: durationSeconds.isFinite ? durationSeconds : 0
        )
        project.thumbnailFilename = await generateThumbnail(for: asset, baseFilename: filename)
        return project
    }

    /// Grabs the frame at t=0 and saves it as a JPEG next to the video.
    /// Returns nil (rather than throwing) on failure — a missing thumbnail
    /// just falls back to a placeholder icon in the UI, it shouldn't block
    /// the import.
    private static func generateThumbnail(for asset: AVURLAsset, baseFilename: String) async -> String? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        let cgImage: CGImage? = await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, _, _ in
                continuation.resume(returning: image)
            }
        }

        guard let cgImage, let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) else {
            return nil
        }

        let thumbFilename = "\(baseFilename)-thumb.jpg"
        try? data.write(to: videosDirectory.appending(path: thumbFilename))
        return thumbFilename
    }

    static func loadProjects() -> [VideoProject] {
        guard let data = try? Data(contentsOf: projectsFileURL) else { return [] }
        return (try? JSONDecoder().decode([VideoProject].self, from: data)) ?? []
    }

    static func save(_ projects: [VideoProject]) {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: projectsFileURL, options: .atomic)
    }

    static func deleteProject(_ project: VideoProject) {
        try? FileManager.default.removeItem(at: sourceURL(forFilename: project.sourceFilename))
        if let thumbnailFilename = project.thumbnailFilename {
            try? FileManager.default.removeItem(at: thumbnailURL(forFilename: thumbnailFilename))
        }
    }
}
