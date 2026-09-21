import Foundation
import PencilKit

/// One Procreate-style annotation layer: a named, independently
/// show/hide-able, reorderable, deletable unit of ink — the unit the
/// Layers panel operates on, the same role a raster layer plays in
/// Procreate. Unlike Procreate, a layer is also scoped to a time range
/// (`startTime`/`endTime`, same convention as ZoomKeyframe): its ink only
/// appears in playback/export during that window, chosen once per layer
/// rather than per stroke.
struct DrawingLayer: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var isVisible: Bool
    var startTime: Double
    var endTime: Double
    /// The on-screen editing canvas size (points) the strokes in
    /// `drawingData` were authored against. PKDrawing records stroke
    /// geometry in that canvas's own coordinate space, so VideoComposer
    /// needs this to scale ink correctly onto the (usually much larger)
    /// export render size. CGSize itself isn't Codable, hence two Doubles
    /// — same convention NormalizedRect/ZoomKeyframe use elsewhere.
    var canvasWidth: Double
    var canvasHeight: Double
    /// A PencilKit `PKDrawing`, serialized via `.dataRepresentation()`.
    var drawingData: Data

    init(
        id: UUID = UUID(),
        name: String,
        isVisible: Bool = true,
        startTime: Double,
        endTime: Double,
        canvasWidth: Double,
        canvasHeight: Double,
        drawingData: Data = PKDrawing().dataRepresentation()
    ) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.startTime = startTime
        self.endTime = endTime
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.drawingData = drawingData
    }
}
