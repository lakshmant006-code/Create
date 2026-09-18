import SwiftUI

struct BackgroundControlsView: View {
    var viewModel: EditorViewModel
    @State private var backgroundTab: BackgroundTab = .gradient

    private enum BackgroundTab: String, CaseIterable, Identifiable {
        case color = "Color"
        case gradient = "Gradient"
        case none = "None"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            section("Aspect Ratio") {
                Picker("Aspect Ratio", selection: Binding(
                    get: { viewModel.project.aspectRatio },
                    set: { newValue in
                        viewModel.project.aspectRatio = newValue
                        Task { await viewModel.reloadPreview() }
                    }
                )) {
                    ForEach(AspectRatioPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }

            section("Background") {
                // A custom Binding here (rather than @State + .onChange)
                // means switching tabs only applies a default background
                // when the *user* taps a tab — not when this view syncs
                // its tab selection to an already-loaded project on
                // appear.
                Picker("Background Type", selection: Binding(
                    get: { backgroundTab },
                    set: { newTab in
                        backgroundTab = newTab
                        applyDefault(for: newTab)
                    }
                )) {
                    ForEach(BackgroundTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                if backgroundTab != .none {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 10) {
                        ForEach(Array(presets(for: backgroundTab).enumerated()), id: \.offset) { _, style in
                            swatch(for: style)
                        }
                    }
                }
            }

            section("Padding") {
                labeledSlider("Padding", value: sliderBinding(\.paddingFraction), range: 0...0.35, isPercent: true)
            }

            section("Corner Radius") {
                labeledSlider("Radius", value: sliderBinding(\.cornerRadius), range: 0...80, suffix: "px")
            }

            section("Shadow") {
                Toggle("Draw Shadow", isOn: Binding(
                    get: { viewModel.project.shadowOpacity > 0 },
                    set: { isOn in
                        viewModel.project.shadowOpacity = isOn ? 0.5 : 0
                        Task { await viewModel.reloadPreview() }
                    }
                ))
                if viewModel.project.shadowOpacity > 0 {
                    labeledSlider("Blur", value: sliderBinding(\.shadowRadius), range: 0...100, suffix: "px")
                    labeledSlider("Offset Y", value: sliderBinding(\.shadowOffsetY), range: -50...50, suffix: "px")
                    labeledSlider("Offset X", value: sliderBinding(\.shadowOffsetX), range: -50...50, suffix: "px")
                    labeledSlider("Opacity", value: sliderBinding(\.shadowOpacity), range: 0...1, isPercent: true)
                }
            }

            section("Trim") {
                Text(String(format: "%.1fs – %.1fs", viewModel.project.trimStart, viewModel.project.trimEnd))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: sliderBinding(\.trimStart),
                    in: 0...max(viewModel.project.trimEnd - 0.2, 0),
                    onEditingChanged: reloadWhenDone
                )
                Slider(
                    value: sliderBinding(\.trimEnd),
                    in: min(viewModel.project.trimStart + 0.2, viewModel.duration)...max(viewModel.duration, 0.21),
                    onEditingChanged: reloadWhenDone
                )
            }

            if let selectedID = viewModel.selectedKeyframeID {
                section("Selected Zoom") {
                    Button(role: .destructive) {
                        viewModel.removeKeyframe(selectedID)
                    } label: {
                        Label("Remove Zoom", systemImage: "trash")
                    }
                }
            }

            section("Draw") {
                Toggle("Draw Mode", isOn: Binding(
                    get: { viewModel.isDrawingModeActive },
                    set: { viewModel.setDrawingMode($0) }
                ))

                if viewModel.isDrawingModeActive {
                    Text("Pen, pencil, eraser, color and size are in the floating toolbar over the preview. Layers below.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(viewModel.project.drawingLayers) { layer in
                            layerRow(layer)
                        }
                    }

                    Button {
                        viewModel.addDrawingLayer()
                    } label: {
                        Label("Add Layer", systemImage: "plus.square.on.square")
                    }
                    .font(.caption)

                    if let activeID = viewModel.activeLayerID,
                       let activeLayer = viewModel.project.drawingLayers.first(where: { $0.id == activeID }) {
                        activeLayerControls(activeLayer)
                    }
                }
            }
        }
        .onAppear {
            switch viewModel.project.background {
            case .solid: backgroundTab = .color
            case .gradient: backgroundTab = .gradient
            case .none: backgroundTab = .none
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func labeledSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String = "",
        isPercent: Bool = false
    ) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(isPercent ? "\(Int(value.wrappedValue * 100))%" : "\(Int(value.wrappedValue))\(suffix)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        Slider(value: value, in: range, onEditingChanged: reloadWhenDone)
    }

    private func layerRow(_ layer: DrawingLayer) -> some View {
        let isActive = layer.id == viewModel.activeLayerID
        return HStack(spacing: 8) {
            Button {
                viewModel.toggleLayerVisibility(layer.id)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)

            Text(layer.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.moveDrawingLayer(layer.id, up: true)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.project.drawingLayers.last?.id == layer.id)

            Button {
                viewModel.moveDrawingLayer(layer.id, up: false)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.project.drawingLayers.first?.id == layer.id)

            Button(role: .destructive) {
                viewModel.deleteDrawingLayer(layer.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(8)
        .background(isActive ? Color.orange.opacity(0.15) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.activeLayerID = layer.id
        }
    }

    @ViewBuilder
    private func activeLayerControls(_ layer: DrawingLayer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\"\(layer.name)\" visible \(String(format: "%.1fs", layer.startTime))–\(String(format: "%.1fs", layer.endTime))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Slider(
                value: layerTimeBinding(layer.id, \.startTime),
                in: 0...max(layer.endTime - 0.2, 0),
                onEditingChanged: reloadWhenDone
            )
            Slider(
                value: layerTimeBinding(layer.id, \.endTime),
                in: min(layer.startTime + 0.2, viewModel.duration)...max(viewModel.duration, 0.21),
                onEditingChanged: reloadWhenDone
            )

            Button(role: .destructive) {
                viewModel.clearDrawingLayer(layer.id)
            } label: {
                Label("Clear Layer", systemImage: "trash")
            }
            .font(.caption)
        }
    }

    private func layerTimeBinding(_ layerID: UUID, _ keyPath: KeyPath<DrawingLayer, Double>) -> Binding<Double> {
        Binding(
            get: {
                viewModel.project.drawingLayers.first(where: { $0.id == layerID })?[keyPath: keyPath] ?? 0
            },
            set: { newValue in
                guard let layer = viewModel.project.drawingLayers.first(where: { $0.id == layerID }) else { return }
                let start = keyPath == \DrawingLayer.startTime ? newValue : layer.startTime
                let end = keyPath == \DrawingLayer.endTime ? newValue : layer.endTime
                viewModel.updateLayerTimeRange(layerID, startTime: start, endTime: end)
            }
        )
    }

    private func presets(for tab: BackgroundTab) -> [BackgroundStyle] {
        switch tab {
        case .color: return BackgroundStyle.colorPresets
        case .gradient: return BackgroundStyle.gradientPresets
        case .none: return []
        }
    }

    private func applyDefault(for tab: BackgroundTab) {
        switch tab {
        case .color:
            viewModel.project.background = BackgroundStyle.colorPresets.first ?? .solid(.black)
        case .gradient:
            viewModel.project.background = BackgroundStyle.gradientPresets.first ?? .solid(.black)
        case .none:
            viewModel.project.background = .none
        }
        Task { await viewModel.reloadPreview() }
    }

    private func swatch(for style: BackgroundStyle) -> some View {
        let isSelected = viewModel.project.background == style
        return Button {
            viewModel.project.background = style
            Task { await viewModel.reloadPreview() }
        } label: {
            RoundedRectangle(cornerRadius: 10)
                .fill(fillStyle(for: style))
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                )
        }
        .buttonStyle(.plain)
    }

    private func fillStyle(for style: BackgroundStyle) -> AnyShapeStyle {
        switch style {
        case .solid(let color):
            return AnyShapeStyle(color.color)
        case .gradient(let start, let end):
            return AnyShapeStyle(LinearGradient(colors: [start.color, end.color], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .none:
            return AnyShapeStyle(Color.clear)
        }
    }

    /// Two-way binding into a Double field on the project. The preview
    /// rebuild is intentionally *not* triggered here — see
    /// `reloadWhenDone` — so dragging a slider stays smooth instead of
    /// rebuilding the whole AVFoundation composition every frame.
    private func sliderBinding(_ keyPath: WritableKeyPath<VideoProject, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.project[keyPath: keyPath] },
            set: { viewModel.project[keyPath: keyPath] = $0 }
        )
    }

    private func reloadWhenDone(_ isEditing: Bool) {
        guard !isEditing else { return }
        Task { await viewModel.reloadPreview() }
    }
}
