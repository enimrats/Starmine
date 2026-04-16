import SwiftUI

struct JellyfinArtworkView: View {
    let url: URL?
    let placeholderSystemName: String
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Palette.selection.opacity(0.95),
                            Palette.accent.opacity(0.62),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let url {
                Color.clear
                    .overlay {
                        AsyncImage(
                            url: url,
                            transaction: .init(
                                animation: .easeInOut(duration: 0.18)
                            )
                        ) { phase in
                            switch phase {
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .failure, .empty:
                                placeholder
                            @unknown default:
                                placeholder
                            }
                        }
                    }
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: cornerRadius,
                            style: .continuous
                        )
                    )
            } else {
                placeholder
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Palette.selection, Palette.accent.opacity(0.74),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: placeholderSystemName)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}
