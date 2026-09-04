import SwiftUI

/// ChatGPT-style loading placeholders: quiet monochrome blocks with a slow
/// light sweep, standing in for content that is still loading. The sweep is
/// static under Reduce Motion; placeholders never move or spin.

/// One placeholder block carrying the shared shimmer sweep.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 6
    /// Per-row stagger (0-1) so columns of blocks shimmer out of phase
    /// instead of pulsing as one wall.
    var phaseOffset: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.12))
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [.clear, Color.primary.opacity(0.22), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width * 0.9)
                    .offset(x: reduceMotion ? 0 : phase * geometry.size.width * 1.9)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .allowsHitTesting(false)
            )
            .task(id: reduceMotion) {
                guard !reduceMotion else { return }
                phase = -1 + phaseOffset
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
            .accessibilityHidden(true)
    }
}

/// A placeholder row shaped like the app's compressed rows: a leading
/// rounded-square icon and one or two text lines of varying width.
struct SkeletonRow: View {
    var showsSubtitle = false
    var titleWidthFraction: CGFloat = 0.58
    var phaseOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(cornerRadius: 7, phaseOffset: phaseOffset)
                .frame(width: 26, height: 26)
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(phaseOffset: phaseOffset)
                        .frame(width: geometry.size.width * titleWidthFraction, height: 10)
                    if showsSubtitle {
                        SkeletonBlock(phaseOffset: phaseOffset)
                            .frame(width: geometry.size.width * 0.4, height: 8)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// A column of placeholder rows that reads like the loaded list, with
/// per-row line-width variation so it never looks like a uniform grid.
struct SkeletonListView: View {
    var count = 8
    var showsSubtitle = false
    var rowHeight: CGFloat = 34
    var horizontalPadding: CGFloat = 20
    var accessibilityLabel: String

    private static let titleFractions: [CGFloat] = [
        0.62, 0.44, 0.58, 0.36, 0.52, 0.68, 0.4, 0.55,
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<max(count, 0), id: \.self) { index in
                SkeletonRow(
                    showsSubtitle: showsSubtitle,
                    titleWidthFraction: Self.titleFractions[index % Self.titleFractions.count],
                    phaseOffset: CGFloat(index % 5) * 0.2
                )
                .frame(height: rowHeight)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Placeholder chat transcript for shared snapshots and other message
/// surfaces: alternating user-style (trailing) and assistant-style (leading)
/// bubbles over a full-width block, echoing the finished layout.
struct SkeletonConversationView: View {
    var accessibilityLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<6, id: \.self) { index in
                if index % 2 == 0 {
                    SkeletonBlock(cornerRadius: 14)
                        .frame(width: 210, height: 16)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        SkeletonBlock(cornerRadius: 7)
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock()
                                .frame(height: 12)
                            SkeletonBlock()
                                .frame(width: 190, height: 12)
                            SkeletonBlock()
                                .frame(width: 150, height: 12)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}
