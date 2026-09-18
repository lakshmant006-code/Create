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

    /// Relocates a video the user just picked (Photos or Files) into the
    /// sandbox and creates a fresh project pointed at it — the thumbnail
    /// generates in the background afterward (see below) rather than
    /// blocking this call, since import jumps straight into the editor
    /// without ever showing the grid card the thumbnail is for.
    /// `temporaryURL` only needs to be valid for this call. Rejects
    /// anything over `maxImportSizeBytes` up front, before touching it.
    ///
    /// `ownsSource`: pass `true` only when `temporaryURL` is a disposable
    /// file this call is the sole owner of (e.g. our own temp copy from
    /// the Photos picker) — it's then *moved* into place, which on the
    /// same volume is a fast rename instead of a full byte-for-byte copy,
    /// unlike a user's original document from the Files importer, which
    /// must never be moved/deleted out from under them.
    static func importVideo(from temporaryURL: URL, name: String, ownsSource: Bool = false) async throws -> VideoProject {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path),
           let sizeInBytes = attributes[.size] as? Int,
           sizeInBytes > maxImportSizeBytes {
            throw ImportError.fileTooLarge
        }

        let ext = temporaryURL.pathExtension.isEmpty ? "mov" : temporaryURL.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = videosDirectory.appending(path: filename)

        do {
            if ownsSource {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            } else {
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
            }

            let asset = AVURLAsset(url: destination)
            let durationSeconds = try await asset.load(.duration).seconds

            let project = VideoProject(
                name: name,
                sourceFilename: filename,
                duration: durationSeconds.isFinite ? durationSeconds : 0
            )
            generateThumbnailInBackground(for: project, asset: asset, baseFilename: filename)
            return project
        } catch {
            // Don't leave an orphaned copy in Documents/Videos if duration
            // loading fails after the copy succeeded — repeated failed
            // imports (an unsupported/damaged file) would otherwise quietly
            // eat storage forever, since nothing else ever references this
            // filename to clean it up later.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Fires off thumbnail generation without making the caller wait for
    /// it, then patches the finished filename into whatever's saved for
    /// this project once it's ready. Safe even though the caller
    /// (finishImport) saves this same project moments after importVideo
    /// returns, before this finishes: that save's own loadProjects() runs
    /// first regardless (thumbnail decode is slower than an array append +
    /// small JSON write), so by the time this task's loadProjects() runs,
    /// the project is already there to patch. In the unlikely case that
    /// ordering ever flips, the project simply keeps its placeholder icon
    /// — never lost data, just a missed thumbnail.
    private static func generateThumbnailInBackground(for project: VideoProject, asset: AVURLAsset, baseFilename: String) {
        Task {
            guard let thumbnailFilename = await generateThumbnail(for: asset, baseFilename: baseFilename) else { return }
            var projects = loadProjects()
            guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
            projects[index].thumbnailFilename = thumbnailFilename
            save(projects)
        }
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

    /// Returns `[]` when there's genuinely no saved project list yet (first
    /// launch). If `projects.json` exists but fails to decode, that's a
    /// different situation — silently treating it the same as "no
    /// projects" would let the very next `save()` (e.g. from importing one
    /// new video) overwrite the file with just that one project, discarding
    /// whatever was in it for good. So a corrupted file is preserved as a
    /// `.corrupt` backup instead of being left in place to get clobbered.
    static func loadProjects() -> [VideoProject] {
        guard let data = try? Data(contentsOf: projectsFileURL) else { return [] }
        if let projects = try? JSONDecoder().decode([VideoProject].self, from: data) {
            return projects
        }
        let backupURL = projectsFileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: projectsFileURL, to: backupURL)
        return []
    }

    @discardableResult
    static func save(_ projects: [VideoProject]) -> Bool {
        guard let data = try? JSONEncoder().encode(projects) else { return false }
        return (try? data.write(to: projectsFileURL, options: .atomic)) != nil
    }

    static func deleteProject(_ project: VideoProject) {
        try? FileManager.default.removeItem(at: sourceURL(forFilename: project.sourceFilename))
        if let thumbnailFilename = project.thumbnailFilename {
            try? FileManager.default.removeItem(at: thumbnailURL(forFilename: thumbnailFilename))
        }
    }
}
