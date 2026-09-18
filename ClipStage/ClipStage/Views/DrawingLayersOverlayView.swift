import SwiftUI
import PencilKit

/// Stacks every visible drawing layer as its own PencilKit canvas over the
/// (paused) video preview — only the active layer accepts input; the rest
/// render read-only, for reference, the way Procreate shows layers below
/// the one you're working on.
///
/// Unlike VideoComposer's baked render, this editing surface ignores each
/// layer's time range entirely and always shows every visible layer — you
/// draw here without needing to be scrubbed into a layer's window first.
/// A layer's time range only decides when its ink actually appears in
/// playback/export (see VideoComposer.swift).
struct DrawingLayersOverlayView: View {
    var viewModel: EditorViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(viewModel.project.drawingLayers) { layer in
                    if layer.isVisible {
                        DrawingCanvasView(
                            drawing: drawingBinding(for: layer.id),
                            isActive: layer.id == viewModel.activeLayerID,
                            tool: viewModel.currentPKTool
                        )
                    }
                }
            }
            .onAppear {
                viewModel.canvasSize = geo.size
                viewModel.ensureActiveLayer()
            }
            .onChange(of: geo.size) { _, newSize in
                viewModel.canvasSize = newSize
            }
        }
    }

    private func drawingBinding(for layerID: UUID) -> Binding<PKDrawing> {
        Binding(
            get: {
                guard let layer = viewModel.project.drawingLayers.first(where: { $0.id == layerID }) else {
                    return PKDrawing()
                }
                return (try? PKDrawing(data: layer.drawingData)) ?? PKDrawing()
            },
            set: { newDrawing in
                viewModel.updateLayerDrawing(layerID, drawing: newDrawing)
            }
        )
    }
}
