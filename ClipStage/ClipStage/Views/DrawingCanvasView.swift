import SwiftUI
import PencilKit

/// Wraps one PKCanvasView for one drawing layer — real PencilKit ink
/// (pressure/tilt-sensitive, smoothed, palm-rejecting per the system's
/// "Only Draw with Apple Pencil" setting) without using the system
/// `PKToolPicker` chrome: `tool` is driven entirely by this app's own
/// floating toolbar (see DrawingToolbarView), and pushed straight onto
/// the canvas view.
struct DrawingCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var isActive: Bool
    var tool: PKTool

    func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.drawing = drawing
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .default
        canvasView.tool = tool
        canvasView.delegate = context.coordinator
        return canvasView
    }

    func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        if canvasView.drawing != drawing {
            canvasView.drawing = drawing
        }
        canvasView.isUserInteractionEnabled = isActive
        canvasView.tool = tool
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}
