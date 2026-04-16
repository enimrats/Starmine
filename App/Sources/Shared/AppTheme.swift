import SwiftUI

enum Palette {
    static let accent = Color(red: 0.94, green: 0.38, blue: 0.17)
    static let accentDeep = Color(red: 0.79, green: 0.23, blue: 0.08)
    static let canvas = Color(red: 0.95, green: 0.93, blue: 0.89)
    static let sidebarBackground = Color(red: 0.92, green: 0.90, blue: 0.86)
    static let surface = Color.white.opacity(0.82)
    static let selection = Color(red: 1.0, green: 0.84, blue: 0.78)
    static let ink = Color(red: 0.14, green: 0.13, blue: 0.12)
}

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(Palette.ink.opacity(0.65))
    }
}

struct StatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Palette.ink.opacity(0.56))
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
        }
    }
}

struct HeaderCapsule: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(Palette.ink.opacity(0.82))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.8))
        )
    }
}

struct PillLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.14))
            )
    }
}

struct StatPill: View {
    let text: String
    var emphasized = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(emphasized ? 0.98 : 0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        emphasized
                            ? Palette.accent.opacity(0.88)
                            : .white.opacity(0.14)
                    )
            )
    }
}

struct MenuChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 180)
        .background(
            Capsule(style: .continuous)
                .fill(.white.opacity(0.14))
        )
    }
}

extension View {
    func cardStyle() -> some View {
        padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Palette.surface)
            )
    }

    func panelStyle(cornerRadius: CGFloat = 24) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.82))
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.72), lineWidth: 1)
        }
    }
}
