import SwiftUI

/// A script line whose words can be tapped for their meaning in the learner's home language.
/// Words without a known meaning render as plain text.
struct GlossedLine: View {
    let text: String
    let scene: SceneClip
    let language: HomeLanguage
    let fontSize: CGFloat
    @State private var selectedIndex: Int?

    private var words: [String] { text.split(separator: " ").map(String.init) }

    var body: some View {
        FlowLayout(spacing: fontSize * 0.28, lineSpacing: 2) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                if let meaning = scene.meaning(of: word, in: language) {
                    Button {
                        selectedIndex = index
                    } label: {
                        Text(word)
                            .underline(pattern: .dot, color: Palette.placeholder)
                            .foregroundStyle(Palette.textPrimary)
                            .background {
                                if selectedIndex == index {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Palette.surfaceRaised)
                                        .padding(-3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: isSelected(index)) {
                        WordMeaning(word: Glossary.key(for: word), meaning: meaning)
                            .presentationCompactAdaptation(.popover)
                    }
                    .accessibilityHint("Shows what it means")
                } else {
                    Text(word)
                        .foregroundStyle(Palette.textPrimary)
                }
            }
        }
        .dubFont(fontSize, weight: .bold)
    }

    private func isSelected(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedIndex == index },
            set: { isPresented in
                if !isPresented { selectedIndex = nil }
            }
        )
    }
}

private struct WordMeaning: View {
    let word: String
    let meaning: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(word)
                .dubFont(15, weight: .semibold)
                .foregroundStyle(Palette.textSecondary)
            Text(meaning)
                .dubFont(20, weight: .semibold)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 140, maxWidth: 280, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Lays children out left to right, wrapping to a new row when the width runs out, like words in a paragraph.
struct FlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height)), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty && proposedWidth > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
