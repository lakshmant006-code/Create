import Foundation
import AVFoundation
import Observation
import PencilKit
import CoreGraphics

enum DrawingToolKind {
    case pen, pencil, eraser
}

@MainActor
@Observable
final class EditorViewModel {
    var project: VideoProject
    let sourceURL: URL

    let player = AVPlayer()
    var currentTime: Double = 0
    var isPlaying = false
    var duration: Double = 1
    var selectedKeyframeID: UUID?
    /// The source video's true (orientation-corrected) size, filled in
    /// once the first preview build loads it. Used by EditorView to size
    /// the `.original` aspect ratio's preview box correctly instead of
    /// guessing 16:9 — see EditorView.contentAspectRatio.
    var sourceNaturalSize = CGSize(width: 16, height: 9)

    var isExporting = false
    var exportProgress: Double = 0
    var exportedFileURL: URL?
    var errorMessage: String?
    var lastSavedAt: Date?

    // Draw — layers live in `project.drawingLayers` (persisted); the rest
    // here is ephemeral tool/UI state. `canvasSize` is set by whichever
    // view lays out the drawing canvas, so a freshly added layer records
    // the coordinate space its ink will be authored in (see DrawingLayer).
    var isDrawingModeActive = false
    var activeLayerID: UUID?
    var canvasSize = CGSize(width: 1, height: 1)
    var drawingToolKind: DrawingToolKind = .pen
    var drawColor: RGBAColor = .white
    var drawLineWidth: Double = 8
    private var hasPendingLayerChanges = false

    /// The PencilKit tool driven by this view model's own floating
    /// toolbar UI — the system `PKToolPicker` is intentionally not used,
    /// so this is the only thing selecting what a stroke draws as.
    var currentPKTool: PKTool {
        switch drawingToolKind {
        case .pen:
            return PKInkingTool(.pen, color: drawColor.uiColor, width: CGFloat(drawLineWidth))
        case .pencil:
            return PKInkingTool(.pencil, color: drawColor.uiColor, width: CGFloat(drawLineWidth))
        case .eraser:
            return PKEraserTool(.bitmap)
        }
    }

    private var timeObserverToken: Any?

    init(project: VideoProject, sourceURL: URL) {
        self.project = project
        self.sourceURL = sourceURL
        self.duration = project.trimmedDuration
        Task { await reloadPreview() }
    }

    /// Rebuilds the composited preview after an edit (background, padding,
    /// zoom keyframes, trim, aspect ratio) so the preview always matches
    /// what export will produce. Every edit calls this — background,
    /// padding, trim, zoom, drawing — so it captures and restores the
    /// playhead (and resumes playback if it was running) instead of
    /// letting `replaceCurrentItem` silently reset a fresh AVPlayerItem to
    /// time zero on every single edit.
    func reloadPreview() async {
        do {
            let resumeTime = min(max(currentTime, 0), project.trimmedDuration)
            let wasPlaying = isPlaying
            let (item, sourceSize) = try await VideoComposer.buildPlayerItem(for: project, sourceURL: sourceURL)
            attachTimeObserver(to: item)
            player.replaceCurrentItem(with: item)
            duration = project.trimmedDuration
            sourceNaturalSize = sourceSize
            _ = await player.seek(
                to: CMTime(seconds: resumeTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            currentTime = resumeTime
            if wasPlaying {
                player.play()
            }
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't build preview: \(error.localizedDescription)"
        }
    }

    private func attachTimeObserver(to item: AVPlayerItem) {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        // Hops to the main actor properly instead of asserting we're
        // already on it (MainActor.assumeIsolated traps if that assumption
        // is ever wrong — this can't).
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds
            }
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        isPlaying = true
        if hasPendingLayerChanges {
            // reloadPreview() (via syncPendingLayerChanges) reads
            // `isPlaying`, already true above, and resumes playback
            // itself once the rebuilt item is seeked back to the current
            // playhead — no separate player.play() needed here too.
            Task { await syncPendingLayerChanges() }
        } else {
            player.play()
        }
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func addZoomKeyframe(at time: Double) {
        let keyframe = ZoomKeyframe(
            startTime: time,
            targetRect: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        )
        project.zoomKeyframes.append(keyframe)
        selectedKeyframeID = keyframe.id
        Task { await reloadPreview() }
    }

    func removeKeyframe(_ id: UUID) {
        project.zoomKeyframes.removeAll { $0.id == id }
        if selectedKeyframeID == id { selectedKeyframeID = nil }
        Task { await reloadPreview() }
    }

    func updateKeyframeRect(_ id: UUID, rect: NormalizedRect) {
        guard let index = project.zoomKeyframes.firstIndex(where: { $0.id == id }) else { return }
        project.zoomKeyframes[index].targetRect = rect
        Task { await reloadPreview() }
    }

    /// Entering draw mode pauses playback — drawing over a moving video
    /// isn't useful. Doesn't create a first layer itself: that needs
    /// `canvasSize` to already reflect the real on-screen canvas, which
    /// isn't known until the drawing overlay's own GeometryReader has
    /// appeared — see `ensureActiveLayer()`, called from there instead,
    /// after `canvasSize` is set.
    func setDrawingMode(_ active: Bool) {
        isDrawingModeActive = active
        if active {
            player.pause()
            isPlaying = false
        } else {
            Task { await syncPendingLayerChanges() }
        }
    }

    /// Called by the drawing overlay once it knows the real canvas size —
    /// creates a first layer if the project has none yet, or just picks
    /// an active layer if one isn't selected.
    func ensureActiveLayer() {
        if project.drawingLayers.isEmpty {
            addDrawingLayer()
        } else if activeLayerID == nil {
            activeLayerID = project.drawingLayers.first?.id
        }
    }

    /// Adds a new layer, visible for the whole trimmed clip by default,
    /// and makes it the active (editable) one. `canvasSize` is whatever
    /// the drawing canvas last reported laying out at — see DrawingLayer
    /// for why that's recorded per layer.
    func addDrawingLayer() {
        let layer = DrawingLayer(
            name: "Layer \(project.drawingLayers.count + 1)",
            startTime: 0,
            endTime: project.trimmedDuration,
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height
        )
        project.drawingLayers.append(layer)
        activeLayerID = layer.id
        // Nothing to reload yet — a freshly added layer is empty, so it
        // can't change what's currently rendered until it has ink.
    }

    func deleteDrawingLayer(_ id: UUID) {
        project.drawingLayers.removeAll { $0.id == id }
        if activeLayerID == id { activeLayerID = project.drawingLayers.first?.id }
        Task { await reloadPreview() }
    }

    func toggleLayerVisibility(_ id: UUID) {
        guard let index = project.drawingLayers.firstIndex(where: { $0.id == id }) else { return }
        project.drawingLayers[index].isVisible.toggle()
        Task { await reloadPreview() }
    }

    func renameDrawingLayer(_ id: UUID, to name: String) {
        guard let index = project.drawingLayers.firstIndex(where: { $0.id == id }) else { return }
        project.drawingLayers[index].name = name
    }

    /// Moves a layer one slot toward the top (`up: true`) or bottom of the
    /// visual stack. Both `DrawingLayersOverlayView`'s `ZStack` and
    /// `VideoComposer`'s `addSublayer` calls render `drawingLayers` in
    /// array order with *later* entries on top — so "up" (toward the
    /// front, like every layer panel: Procreate, Photoshop, Keynote) means
    /// moving to a *higher* array index, not a lower one.
    func moveDrawingLayer(_ id: UUID, up: Bool) {
        guard let index = project.drawingLayers.firstIndex(where: { $0.id == id }) else { return }
        let newIndex = up ? index + 1 : index - 1
        guard project.drawingLayers.indices.contains(newIndex) else { return }
        project.drawingLayers.swapAt(index, newIndex)
        Task { await reloadPreview() }
    }

    /// Bound to the active layer's time-range sliders — like
    /// `sliderBinding` in BackgroundControlsView, the reload is deferred
    /// to the slider's own `onEditingChanged(false)`, not triggered here,
    /// so dragging stays smooth.
    func updateLayerTimeRange(_ id: UUID, startTime: Double, endTime: Double) {
        guard let index = project.drawingLayers.firstIndex(where: { $0.id == id }) else { return }
        project.drawingLayers[index].startTime = startTime
        project.drawingLayers[index].endTime = endTime
    }

    /// Wipes a layer's ink without deleting the layer itself.
    func clearDrawingLayer(_ id: UUID) {
        guard let index = project.drawingLayers.firstIndex(where: { $0.id == id }) else { return }
        project.drawingLayers[index].drawingData = PKDrawing().dataRepresentation()
        Task { await reloadPreview() }
    }

    /// Called on every PencilKit `canvasViewDrawingDidChange` — i.e.
    /// continuously while a stroke is being drawn — so it only updates
    /// the model (cheap) and never triggers a preview reload directly.
    /// Rebuilding the whole AVFoundation composition on every ink update
    /// would make drawing visibly stutter; `syncPendingLayerChanges()`
    /// does the one reload once you stop actively drawing (leaving draw
    /// mode or hitting play).
    func updateLayerDrawing(_ id: UUID, drawing: PKDrawing) {
        guard let index = project.drawingLayers.firstIndex(where: { $0.id == id }) else { return }
        project.drawingLayers[index].drawingData = drawing.dataRepresentation()
        hasPendingLayerChanges = true
    }

    private func syncPendingLayerChanges() async {
        guard hasPendingLayerChanges else { return }
        hasPendingLayerChanges = false
        await reloadPreview()
    }

    /// Writes the current in-memory edits back into the persisted project
    /// list. Called from an explicit Save button and also on leaving the
    /// editor, so edits aren't lost either way.
    func save() {
        project.updatedAt = Date()
        var all = ProjectStore.loadProjects()
        if let index = all.firstIndex(where: { $0.id == project.id }) {
            all[index] = project
        } else {
            all.append(project)
        }
        guard ProjectStore.save(all) else {
            errorMessage = "Couldn't save — check available storage and try again."
            return
        }
        lastSavedAt = Date()
    }

    func export() async {
        isExporting = true
        exportProgress = 0
        errorMessage = nil
        exportedFileURL = nil
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "\(project.name)-\(Int(Date().timeIntervalSince1970)).mp4")
        do {
            try await VideoComposer.export(project: project, sourceURL: sourceURL, outputURL: outputURL) { [weak self] value in
                Task { @MainActor in self?.exportProgress = value }
            }
            exportedFileURL = outputURL
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
        }
        isExporting = false
    }
}
