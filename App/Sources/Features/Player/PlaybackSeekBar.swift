import SwiftUI

struct PlaybackSeekBar: View {
    let duration: Double
    let position: Double
    let bufferedTint: Color
    let onScrubStart: () -> Void
    let onScrubChange: (Double) -> Void
    let onScrubEnd: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let progress = normalizedProgress
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.16))
                    .frame(height: 8)

                Capsule(style: .continuous)
                    .fill(bufferedTint.opacity(0.9))
                    .frame(width: proxy.size.width * progress, height: 8)

                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    .offset(
                        x: max(
                            0,
                            min(
                                proxy.size.width - 16,
                                proxy.size.width * progress - 8
                            )
                        )
                    )
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrubStart()
                        onScrubChange(
                            seconds(
                                for: value.location.x,
                                width: proxy.size.width
                            )
                        )
                    }
                    .onEnded { value in
                        onScrubEnd(
                            seconds(
                                for: value.location.x,
                                width: proxy.size.width
                            )
                        )
                    }
            )
        }
        .frame(height: 20)
    }

    private var normalizedProgress: CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, position / duration)))
    }

    private func seconds(for x: CGFloat, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        let progress = max(0, min(1, x / width))
        return duration * progress
    }
}
