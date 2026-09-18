import SwiftUI

/// A draggable rectangle drawn over the video preview so the user can pick
/// where a cinematic zoom pushes in on. v1: drag to reposition, fixed size
/// — resizing handles are a natural next addition.
struct ZoomOverlayView: View {
    let rect: NormalizedRect
    let onChanged: (NormalizedRect) -> Void

    @State private var localRect: NormalizedRect

    init(rect: NormalizedRect, onChanged: @escaping (NormalizedRect) -> Void) {
        self.rect = rect
        self.onChanged = onChanged
        self._localRect = State(initialValue: rect)
    }

    var body: some View {
        GeometryReader { geo in
            let frame = CGRect(
                x: localRect.x * geo.size.width,
                y: localRect.y * geo.size.height,
                width: localRect.width * geo.size.width,
                height: localRect.height * geo.size.height
            )

            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange, lineWidth: 3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            var updated = localRect
                            updated.x = min(max(rect.x + value.translation.width / geo.size.width, 0), 1 - rect.width)
                            updated.y = min(max(rect.y + value.translation.height / geo.size.height, 0), 1 - rect.height)
                            localRect = updated
                        }
                        .onEnded { _ in
                            onChanged(localRect)
                        }
                )
                .onChange(of: rect) { _, newValue in
                    localRect = newValue
                }
        }
    }
}
