import SwiftUI

/// A custom floating pill toolbar over the video preview — pen/pencil/
/// eraser, a color swatch, and a size control — driving
/// EditorViewModel.currentPKTool directly rather than showing the system
/// PKToolPicker, so the look matches the rest of this app's own chrome.
struct DrawingToolbarView: View {
    var viewModel: EditorViewModel
    @State private var showColorPicker = false
    @State private var showSizePicker = false

    var body: some View {
        HStack(spacing: 2) {
            toolButton(.pen, systemImage: "pencil.tip")
            toolButton(.pencil, systemImage: "paintbrush.pointed.fill")
            toolButton(.eraser, systemImage: "eraser.fill")

            Divider()
                .frame(height: 20)
                .overlay(Color.white.opacity(0.2))
                .padding(.horizontal, 6)

            Button {
                showSizePicker = false
                showColorPicker.toggle()
            } label: {
                Circle()
                    .fill(viewModel.drawColor.color)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
            }
            .popover(isPresented: $showColorPicker, arrowEdge: .bottom) {
                colorPickerContent
            }

            Button {
                showColorPicker = false
                showSizePicker.toggle()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Circle()
                        .fill(.white)
                        .frame(
                            width: min(max(viewModel.drawLineWidth, 4), 22),
                            height: min(max(viewModel.drawLineWidth, 4), 22)
                        )
                }
            }
            .popover(isPresented: $showSizePicker, arrowEdge: .bottom) {
                sizePickerContent
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.78), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func toolButton(_ kind: DrawingToolKind, systemImage: String) -> some View {
        let isSelected = viewModel.drawingToolKind == kind
        return Button {
            viewModel.drawingToolKind = kind
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .frame(width: 32, height: 32)
                .background(isSelected ? Color.orange : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var colorPickerContent: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 32))], spacing: 10) {
            ForEach(Array(RGBAColor.drawPresets.enumerated()), id: \.offset) { _, color in
                Button {
                    viewModel.drawColor = color
                    showColorPicker = false
                } label: {
                    Circle()
                        .fill(color.color)
                        .frame(width: 32, height: 32)
                        .overlay(
                            Circle().stroke(Color.accentColor, lineWidth: viewModel.drawColor == color ? 3 : 0)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 200)
        .presentationCompactAdaptation(.popover)
    }

    private var sizePickerContent: some View {
        VStack(spacing: 8) {
            Text("\(Int(viewModel.drawLineWidth))px")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { viewModel.drawLineWidth },
                set: { viewModel.drawLineWidth = $0 }
            ), in: 2...40)
                .frame(width: 160)
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }
}
