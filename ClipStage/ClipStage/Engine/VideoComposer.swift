import AVFoundation
import CoreGraphics
import QuartzCore
import PencilKit

/// Builds the AVFoundation composition + video composition that turns a
/// plain source video into the "recording on a stage" look: background
/// canvas, padding, rounded corners, drop shadow, and manual cinematic
/// zoom/pan keyframes — all non-destructive until export.
///
/// Marked `@MainActor`: on newer SDKs, several AVFoundation initializers
/// used here (`AVURLAsset(url:)`, `AVPlayerItem(asset:)`,
/// `AVAssetExportSession(asset:presetName:)`) are main-actor isolated.
/// Calling them from a plain nonisolated async context is what was
/// crashing the app right after import — pinning this whole type to the
/// main actor keeps every call on the right thread.
///
/// The technique: raw decoded frames are placed into a plain CALayer
/// (`videoLayer`) that sits inside a normal CALayer tree (background,
/// shadow, rounded-corner mask). AVFoundation fills that placeholder layer
/// with real video content during playback/export via
/// `AVVideoCompositionCoreAnimationTool`, so any CAAnimation attached to
/// `videoLayer` (like the zoom/pan keyframes below) plays as part of the
/// video itself, not just on screen.
@MainActor
enum VideoComposer {

    enum ComposerError: LocalizedError {
        case missingVideoTrack
        case emptyTrimRange
        case invalidVideoDimensions

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack: return "That file doesn't seem to contain a video track."
            case .emptyTrimRange: return "The trim range is empty — start must be before end."
            case .invalidVideoDimensions: return "Couldn't read this video's dimensions — the file may be corrupted."
            }
        }
    }

    /// Shared by both live preview and final export so they never drift
    /// apart.
    static func buildComposition(
        for project: VideoProject,
        sourceURL: URL
    ) async throws -> (composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, sourceSize: CGSize) {

        let asset = AVURLAsset(url: sourceURL)
        // Video and audio tracks loaded concurrently (async let), and
        // naturalSize/preferredTransform batched into one load(_:_:) call
        // instead of two — this is called on every single edit (see
        // EditorViewModel.reloadPreview) and every project open, so fewer
        // round-trips through AVFoundation's asynchronous key-value
        // loading noticeably cuts latency, especially on a large file.
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        guard let sourceVideoTrack = try await videoTracks.first else {
            throw ComposerError.missingVideoTrack
        }

        let (naturalSize, preferredTransform) = try await sourceVideoTrack.load(.naturalSize, .preferredTransform)
        let orientedSize = naturalSize.applying(preferredTransform)
        let sourceSize = CGSize(width: abs(orientedSize.width), height: abs(orientedSize.height))

        // Guards against a hard Core Animation crash: handing a NaN or
        // zero-sized frame to a CALayer (which happens further down if
        // sourceSize is bad) is not a catchable Swift error, it's a fatal
        // exception. Catching it here instead, as a normal thrown error.
        guard
            sourceSize.width.isFinite, sourceSize.height.isFinite,
            sourceSize.width > 0, sourceSize.height > 0
        else {
            throw ComposerError.invalidVideoDimensions
        }

        let trimStart = CMTime(seconds: project.trimStart, preferredTimescale: 600)
        let trimEnd = CMTime(seconds: project.trimEnd, preferredTimescale: 600)
        let trimRange = CMTimeRange(start: trimStart, end: trimEnd)
        guard trimRange.duration.seconds > 0 else { throw ComposerError.emptyTrimRange }

        // --- Trim into a fresh composition ---
        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ComposerError.missingVideoTrack
        }
        try compositionVideoTrack.insertTimeRange(trimRange, of: sourceVideoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = preferredTransform

        if let sourceAudioTrack = try await audioTracks.first,
           let compositionAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudioTrack.insertTimeRange(trimRange, of: sourceAudioTrack, at: .zero)
        }

        // --- Canvas geometry ---
        let renderSize = project.aspectRatio.renderSize(sourceNaturalSize: sourceSize)
        let shorterEdge = min(renderSize.width, renderSize.height)
        // Clamped defensively: the slider only ever writes 0...0.35, but a
        // persisted value outside that range (hand-edited project.json, a
        // future bug) would otherwise make availableSize below zero or
        // negative, breaking fitScale/contentSize/shadowLayer.frame.
        let clampedPaddingFraction = min(max(project.paddingFraction, 0), 0.35)
        let padding = shorterEdge * CGFloat(clampedPaddingFraction)

        let availableSize = CGSize(width: renderSize.width - padding * 2, height: renderSize.height - padding * 2)
        let fitScale = min(availableSize.width / sourceSize.width, availableSize.height / sourceSize.height)
        let contentSize = CGSize(width: sourceSize.width * fitScale, height: sourceSize.height * fitScale)
        let contentOrigin = CGPoint(
            x: (renderSize.width - contentSize.width) / 2,
            y: (renderSize.height - contentSize.height) / 2
        )
        let contentFrame = CGRect(origin: contentOrigin, size: contentSize)

        // --- Layer tree ---
        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: renderSize)
        // If backgrounds/padding/zoom render upside down or mirrored on
        // your first test build, flip this — see SETUP.md.
        // parentLayer.isGeometryFlipped = true

        parentLayer.addSublayer(project.background.makeLayer(size: renderSize))

        let shadowLayer = CALayer()
        shadowLayer.frame = contentFrame
        if project.shadowOpacity > 0 {
            shadowLayer.shadowColor = CGColor(gray: 0, alpha: 1)
            shadowLayer.shadowOpacity = Float(project.shadowOpacity)
            shadowLayer.shadowRadius = CGFloat(project.shadowRadius)
            shadowLayer.shadowOffset = CGSize(width: CGFloat(project.shadowOffsetX), height: CGFloat(project.shadowOffsetY))
            shadowLayer.shadowPath = CGPath(
                roundedRect: shadowLayer.bounds,
                cornerWidth: CGFloat(project.cornerRadius),
                cornerHeight: CGFloat(project.cornerRadius),
                transform: nil
            )
        }
        parentLayer.addSublayer(shadowLayer)

        let clipLayer = CALayer()
        clipLayer.frame = shadowLayer.bounds
        clipLayer.cornerRadius = CGFloat(project.cornerRadius)
        clipLayer.masksToBounds = true
        clipLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        shadowLayer.addSublayer(clipLayer)

        // Placeholder layer — AVFoundation paints real decoded frames here.
        let videoLayer = CALayer()
        videoLayer.frame = clipLayer.bounds
        clipLayer.addSublayer(videoLayer)

        if !project.zoomKeyframes.isEmpty {
            let animation = makeZoomAnimation(
                keyframes: project.zoomKeyframes.sorted { $0.startTime < $1.startTime },
                layerBounds: videoLayer.bounds,
                totalDuration: trimRange.duration.seconds
            )
            videoLayer.add(animation, forKey: "cinematicZoom")
        }

        for layer in project.drawingLayers where layer.isVisible {
            guard layer.canvasWidth > 0, layer.canvasHeight > 0,
                  let drawing = try? PKDrawing(data: layer.drawingData),
                  !drawing.strokes.isEmpty
            else { continue }

            // Rasterize once at (roughly) export resolution — PKDrawing
            // records stroke geometry in the editing canvas's own point
            // space, which is usually much smaller than the render
            // canvas, so ask for the same logical rect at a higher scale
            // rather than rendering small and stretching a blurry bitmap.
            let canvasBounds = CGRect(x: 0, y: 0, width: layer.canvasWidth, height: layer.canvasHeight)
            let scale = videoLayer.bounds.width / CGFloat(layer.canvasWidth)
            let image = drawing.image(from: canvasBounds, scale: max(scale, 1))
            guard let cgImage = image.cgImage else { continue }

            // A sublayer of videoLayer, not a sibling of it — so ink
            // inherits any transform cinematicZoom applies above and
            // pans/scales together with the footage it's annotating,
            // instead of staying fixed to the canvas. contentsGravity
            // .resize means an imprecise `scale` above still fits
            // correctly, just at lower quality.
            let imageLayer = CALayer()
            imageLayer.frame = videoLayer.bounds
            imageLayer.contents = cgImage
            imageLayer.contentsGravity = .resize
            imageLayer.opacity = 0
            let visibility = makeLayerVisibilityAnimation(
                startTime: layer.startTime,
                endTime: layer.endTime,
                totalDuration: trimRange.duration.seconds
            )
            imageLayer.add(visibility, forKey: "layerVisibility")
            videoLayer.addSublayer(imageLayer)
        }

        let animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.animationTool = animationTool

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: trimRange.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(preferredTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        videoComposition.instructions = [instruction]

        return (composition, videoComposition, sourceSize)
    }

    /// Builds a player item for live, scrubbable preview — same pipeline as
    /// export, so what you see is what you get. Also returns the source's
    /// true (orientation-corrected) size, so callers sizing a `.original`
    /// preview don't have to guess an aspect ratio — see
    /// EditorViewModel.sourceNaturalSize.
    static func buildPlayerItem(
        for project: VideoProject,
        sourceURL: URL
    ) async throws -> (item: AVPlayerItem, sourceSize: CGSize) {
        let (composition, videoComposition, sourceSize) = try await buildComposition(for: project, sourceURL: sourceURL)
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return (item, sourceSize)
    }

    static func export(
        project: VideoProject,
        sourceURL: URL,
        outputURL: URL,
        preset: String = AVAssetExportPresetHighestQuality,
        progress: @escaping (Double) -> Void
    ) async throws {
        let (composition, videoComposition, _) = try await buildComposition(for: project, sourceURL: sourceURL)

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw ComposerError.missingVideoTrack
        }
        exportSession.videoComposition = videoComposition
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.shouldOptimizeForNetworkUse = true

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let progressTask = Task {
            while exportSession.status == .waiting || exportSession.status == .exporting {
                progress(Double(exportSession.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: exportSession.error ?? ComposerError.missingVideoTrack)
                }
            }
        }

        progressTask.cancel()
        progress(1)
    }

    /// Builds a keyframe animation on the video layer's transform: identity
    /// → push in on each zoom target → hold → ease back to identity.
    /// `keyframe.startTime` is already relative to the trimmed clip (it's
    /// captured from the player's own 0-based timeline — see
    /// EditorViewModel.addZoomKeyframe), so no further offset is applied
    /// here.
    private static func makeZoomAnimation(
        keyframes: [ZoomKeyframe],
        layerBounds: CGRect,
        totalDuration: Double
    ) -> CAKeyframeAnimation {
        var values: [CATransform3D] = []
        var keyTimes: [NSNumber] = []
        // CAKeyframeAnimation requires keyTimes to be monotonically
        // increasing. Overlapping zoom keyframes (nothing in the UI
        // prevents adding one while another is still holding/easing out)
        // would otherwise produce a decreasing keyTime here, which the
        // AVFoundation export render server can fail on without raising a
        // catchable error in this process — clamping forward keeps the
        // sequence valid no matter how the keyframes overlap.
        var lastKeyTime = 0.0

        func addKeyframe(time: Double, transform: CATransform3D) {
            guard totalDuration > 0 else { return }
            let clamped = min(max(time, 0), totalDuration)
            let ordered = max(clamped, lastKeyTime)
            lastKeyTime = ordered
            values.append(transform)
            keyTimes.append(NSNumber(value: ordered / totalDuration))
        }

        addKeyframe(time: 0, transform: CATransform3DIdentity)

        for keyframe in keyframes {
            let start = keyframe.startTime
            let zoomInEnd = start + keyframe.holdInDuration
            let holdEnd = zoomInEnd + keyframe.holdDuration
            let zoomOutEnd = holdEnd + keyframe.holdOutDuration
            let transform = zoomTransform(for: keyframe.targetRect, in: layerBounds)

            addKeyframe(time: start, transform: CATransform3DIdentity)
            addKeyframe(time: zoomInEnd, transform: transform)
            addKeyframe(time: holdEnd, transform: transform)
            addKeyframe(time: zoomOutEnd, transform: CATransform3DIdentity)
        }

        addKeyframe(time: totalDuration, transform: CATransform3DIdentity)

        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = values.map { NSValue(caTransform3D: $0) }
        animation.keyTimes = keyTimes
        animation.duration = totalDuration
        animation.calculationMode = .linear
        // Ties the animation to the composition's own zero-based timeline
        // instead of wall-clock time — required for this to render
        // correctly during export, not just live playback.
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        return animation
    }

    /// A transform that scales/translates so `targetRect` (normalized,
    /// 0...1 in the source frame) fills `bounds`, capped so it never zooms
    /// in far enough to look glitchy on a small target box.
    private static func zoomTransform(for targetRect: NormalizedRect, in bounds: CGRect) -> CATransform3D {
        let rect = targetRect.cgRect
        let scaleX = 1 / max(rect.width, 0.05)
        let scaleY = 1 / max(rect.height, 0.05)
        let scale = min(scaleX, scaleY, 6)

        let offsetX = (rect.midX - 0.5) * bounds.width
        let offsetY = (rect.midY - 0.5) * bounds.height

        var transform = CATransform3DIdentity
        transform = CATransform3DTranslate(transform, -offsetX, -offsetY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return transform
    }

    /// Shows a drawing layer's rasterized-ink image layer only between
    /// `startTime` and `endTime` (both relative to the trimmed clip, same
    /// convention as DrawingLayer's own fields), with a short crossfade
    /// so it doesn't hard-pop in and out. Each layer gets its own image
    /// layer and its own animation here — unlike makeZoomAnimation, which
    /// merges every keyframe onto one shared layer's one animation,
    /// there's no cross-layer overlap risk to guard against: this
    /// animation's own six keyTimes are provably non-decreasing by
    /// construction (each is a min/max clamp of the previous), so no
    /// separate monotonic-clamp pass is needed.
    private static func makeLayerVisibilityAnimation(
        startTime: Double,
        endTime: Double,
        totalDuration: Double
    ) -> CAKeyframeAnimation {
        let fade = 0.12
        let clampedStart = min(max(startTime, 0), totalDuration)
        let clampedEnd = min(max(endTime, clampedStart + 0.01), totalDuration)
        let fadeInEnd = min(clampedStart + fade, clampedEnd)
        let fadeOutStart = max(clampedEnd - fade, fadeInEnd)

        let times: [Double] = [0, clampedStart, fadeInEnd, fadeOutStart, clampedEnd, totalDuration]
        let opacities: [Double] = [0, 0, 1, 1, 0, 0]

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = opacities
        animation.keyTimes = totalDuration > 0
            ? times.map { NSNumber(value: $0 / totalDuration) }
            : times.map { _ in NSNumber(value: 0) }
        animation.duration = totalDuration
        animation.calculationMode = .linear
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .forwards
        return animation
    }
}
