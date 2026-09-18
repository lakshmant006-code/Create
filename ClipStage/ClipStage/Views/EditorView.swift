import SwiftUI

struct EditorView: View {
    @State var viewModel: EditorViewModel
    @State private var showExportSheet = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                PreviewPlayerView(player: viewModel.player)
                    .aspectRatio(contentAspectRatio, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding()
                    .overlay {
                        if viewModel.isDrawingModeActive {
                            DrawingLayersOverlayView(viewModel: viewModel)
                                .padding()
                        } else if let id = viewModel.selectedKeyframeID,
                           let keyframe = viewModel.project.zoomKeyframes.first(where: { $0.id == id }) {
                            ZoomOverlayView(rect: keyframe.targetRect) { newRect in
                                viewModel.updateKeyframeRect(id, rect: newRect)
                            }
                            .padding()
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if viewModel.isDrawingModeActive {
                            DrawingToolbarView(viewModel: viewModel)
                                .padding(.bottom, 16)
                        }
                    }

                TimelineView(viewModel: viewModel)
                    .frame(height: 96)
                    .padding(.horizontal)

                HStack(spacing: 20) {
                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }

                    Button {
                        viewModel.addZoomKeyframe(at: viewModel.currentTime)
                    } label: {
                        Label("Add Zoom", systemImage: "plus.magnifyingglass")
                    }

                    Button {
                        viewModel.setDrawingMode(!viewModel.isDrawingModeActive)
                    } label: {
                        Label("Draw", systemImage: "pencil.tip")
                    }
                    .tint(viewModel.isDrawingModeActive ? .orange : nil)

                    Spacer()

                    if let savedAt = viewModel.lastSavedAt {
                        Text("Saved \(savedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        viewModel.save()
                    } label: {
                        Label("Save", systemImage: "checkmark.circle")
                    }

                    Button {
                        showExportSheet = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("SETTINGS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    BackgroundControlsView(viewModel: viewModel)
                }
                .padding()
            }
            .frame(width: 320)
            .background(Color(white: 0.08))
        }
        .background(Color.black)
        .navigationTitle(viewModel.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExportSheet) {
            ExportView(viewModel: viewModel)
        }
        .onDisappear {
            viewModel.save()
        }
    }

    /// Approximates the canvas shape for sizing the SwiftUI preview frame.
    /// `.original` falls back to 16:9 here since the *real* source size
    /// isn't known until VideoComposer loads the asset — cosmetic only,
    /// export always uses the true value.
    private var contentAspectRatio: CGFloat {
        let size = viewModel.project.aspectRatio.renderSize(sourceNaturalSize: CGSize(width: 16, height: 9))
        return size.width / size.height
    }
}
