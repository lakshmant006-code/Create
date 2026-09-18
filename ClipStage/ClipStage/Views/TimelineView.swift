import SwiftUI

struct TimelineView: View {
    var viewModel: EditorViewModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let safeDuration = max(viewModel.duration, 0.01)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)

                ForEach(viewModel.project.zoomKeyframes) { keyframe in
                    let keyframeDuration = keyframe.holdInDuration + keyframe.holdDuration + keyframe.holdOutDuration
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.orange.opacity(viewModel.selectedKeyframeID == keyframe.id ? 0.9 : 0.45))
                        .frame(width: max(6, width * CGFloat(keyframeDuration / safeDuration)))
                        .offset(x: width * CGFloat(keyframe.startTime / safeDuration))
                        .onTapGesture {
                            viewModel.selectedKeyframeID = keyframe.id
                            viewModel.seek(to: keyframe.startTime)
                        }
                }

                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .offset(x: width * CGFloat(viewModel.currentTime / safeDuration))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
                        viewModel.seek(to: Double(fraction) * viewModel.duration)
                    }
            )
        }
    }
}
