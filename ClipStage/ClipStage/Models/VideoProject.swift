import Foundation
import CoreGraphics

/// The complete, persistable description of one editing project.
/// Everything the editor needs to re-render the final video lives here —
/// nothing is baked into pixels until export time, so every control is
/// non-destructive and re-editable.
struct VideoProject: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    /// Filename of the source video inside the app's sandboxed
    /// Documents/Videos folder (see ProjectStore).
    var sourceFilename: String
    /// Filename of a generated JPEG thumbnail in the same folder, if one
    /// was successfully generated at import time.
    var thumbnailFilename: String?
    var createdAt: Date
    var updatedAt: Date

    // Trim
    var trimStart: Double   // seconds
    var trimEnd: Double     // seconds

    // Canvas
    var aspectRatio: AspectRatioPreset
    var background: BackgroundStyle
    var paddingFraction: Double   // 0...0.35, fraction of the shorter canvas edge
    var cornerRadius: Double      // points, in output render space
    var shadowOpacity: Double     // 0...1 — 0 effectively means "no shadow"
    var shadowRadius: Double      // points — shown as "Blur" in the UI
    var shadowOffsetX: Double     // points
    var shadowOffsetY: Double     // points

    // Cinematic zoom (manual — see ZoomKeyframe)
    var zoomKeyframes: [ZoomKeyframe]

    // Freehand annotations (manual — see DrawingLayer)
    var drawingLayers: [DrawingLayer]

    init(
        id: UUID = UUID(),
        name: String,
        sourceFilename: String,
        duration: Double
    ) {
        self.id = id
        self.name = name
        self.sourceFilename = sourceFilename
        self.thumbnailFilename = nil
        self.createdAt = Date()
        self.updatedAt = Date()
        self.trimStart = 0
        self.trimEnd = max(duration, 0.1)
        self.aspectRatio = .original
        self.background = .gradient(
            RGBAColor(red: 0.09, green: 0.10, blue: 0.14),
            RGBAColor(red: 0.25, green: 0.27, blue: 0.36)
        )
        self.paddingFraction = 0.08
        self.cornerRadius = 24
        self.shadowOpacity = 0.5
        self.shadowRadius = 20
        self.shadowOffsetX = 0
        self.shadowOffsetY = 10
        self.zoomKeyframes = []
        self.drawingLayers = []
    }

    var trimmedDuration: Double { max(0.01, trimEnd - trimStart) }

    // Manual Decodable so projects saved before `drawingLayers` existed
    // (already on disk on a device that's been tested with) still load —
    // a missing key decodes as "no layers yet" instead of the whole
    // project list silently disappearing (ProjectStore.loadProjects()
    // discards the entire array on any decode failure). A project saved
    // by the previous draw-tool prototype (which had a `drawingStrokes`
    // key instead) also just decodes as "no layers yet" — that data
    // model is gone, not migrated; drop-in Draw Mode gets you a fresh
    // layer instead of one reconstructed from the old strokes. Encodable
    // stays compiler-synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceFilename = try container.decode(String.self, forKey: .sourceFilename)
        thumbnailFilename = try container.decodeIfPresent(String.self, forKey: .thumbnailFilename)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        trimStart = try container.decode(Double.self, forKey: .trimStart)
        trimEnd = try container.decode(Double.self, forKey: .trimEnd)
        aspectRatio = try container.decode(AspectRatioPreset.self, forKey: .aspectRatio)
        background = try container.decode(BackgroundStyle.self, forKey: .background)
        paddingFraction = try container.decode(Double.self, forKey: .paddingFraction)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        shadowOpacity = try container.decode(Double.self, forKey: .shadowOpacity)
        shadowRadius = try container.decode(Double.self, forKey: .shadowRadius)
        shadowOffsetX = try container.decode(Double.self, forKey: .shadowOffsetX)
        shadowOffsetY = try container.decode(Double.self, forKey: .shadowOffsetY)
        zoomKeyframes = try container.decodeIfPresent([ZoomKeyframe].self, forKey: .zoomKeyframes) ?? []
        drawingLayers = try container.decodeIfPresent([DrawingLayer].self, forKey: .drawingLayers) ?? []
    }
}

/// Output canvas shape. `.original` keeps the source video's own aspect
/// ratio; the others recompose it onto a fixed-ratio canvas the way
/// ScreenArc's aspect-ratio switcher does for YouTube / Shorts / Instagram.
enum AspectRatioPreset: String, Codable, CaseIterable, Identifiable, Hashable {
    case original
    case widescreen16x9
    case vertical9x16
    case square1x1

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .widescreen16x9: return "16:9"
        case .vertical9x16: return "9:16"
        case .square1x1: return "1:1"
        }
    }

    /// `sourceNaturalSize` should already account for the video's own
    /// orientation (see VideoComposer). Caps the long edge at 1920 so
    /// export stays fast; bump this if you want higher-res output.
    func renderSize(sourceNaturalSize: CGSize) -> CGSize {
        switch self {
        case .original:
            // min(), not a flat 1920 — a source already smaller than that
            // (a modest screen recording, say 640x480) would otherwise get
            // upscaled 3x for zero quality benefit, just wasted encode
            // time and output size.
            let longEdge = min(max(sourceNaturalSize.width, sourceNaturalSize.height), 1920)
            let ratio = sourceNaturalSize.width / max(sourceNaturalSize.height, 1)
            if sourceNaturalSize.width >= sourceNaturalSize.height {
                return CGSize(width: longEdge, height: (longEdge / max(ratio, 0.01)).rounded())
            } else {
                return CGSize(width: (longEdge * ratio).rounded(), height: longEdge)
            }
        case .widescreen16x9:
            return CGSize(width: 1920, height: 1080)
        case .vertical9x16:
            return CGSize(width: 1080, height: 1920)
        case .square1x1:
            return CGSize(width: 1080, height: 1080)
        }
    }
}

/// One "camera move": between `startTime` and `endTime` the frame pushes in
/// on `targetRect` (normalized 0...1 coordinates in the *source video's*
/// frame) and holds, then eases back out. There's no click/tap telemetry
/// for an imported video, so the user places these manually — see
/// ZoomOverlayView + TimelineView.
struct ZoomKeyframe: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var startTime: Double
    var holdInDuration: Double
    var holdDuration: Double
    var holdOutDuration: Double
    var targetRect: NormalizedRect

    init(
        id: UUID = UUID(),
        startTime: Double,
        holdInDuration: Double = 0.4,
        holdDuration: Double = 1.6,
        holdOutDuration: Double = 0.4,
        targetRect: NormalizedRect
    ) {
        self.id = id
        self.startTime = startTime
        self.holdInDuration = holdInDuration
        self.holdDuration = holdDuration
        self.holdOutDuration = holdOutDuration
        self.targetRect = targetRect
    }

    var endTime: Double { startTime + holdInDuration + holdDuration + holdOutDuration }
}

/// A rectangle in normalized (0...1 on both axes) coordinates, independent
/// of any particular pixel size — used both for zoom targets and for the
/// on-screen drag overlay that edits them.
struct NormalizedRect: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let fullFrame = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    var cgRect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}
