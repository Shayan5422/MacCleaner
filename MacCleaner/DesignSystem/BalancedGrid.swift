import SwiftUI

/// Places views left to right and wraps them onto new lines when the width runs out
/// (filter chips), so nothing scrolls sideways.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 8) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append((index, size))
            x += size.width + spacing
        }
        return lines.filter { !$0.isEmpty }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        let lines = lines(for: subviews, width: width)
        let heights = lines.map { $0.map(\.size.height).max() ?? 0 }
        let widths = lines.map { line in line.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, line.count - 1)) }
        let height = heights.reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? (widths.max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            let height = line.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in line {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

/// Lays out cards in rows that fill the width and never leave one card alone on the
/// last row: 9 cards become 3 × 3, 4 that fit only 3 per row become 2 × 2, 5 that fit
/// 4 per row become 3 + 2. Cards in a row share its width equally, and every row gets
/// the height of the tallest card, so cards that fill their frame line up.
struct BalancedGrid: Layout {
    /// Cards are never narrower than this (unless the whole width is smaller).
    var minimumItemWidth: CGFloat
    var maximumColumns: Int = .max
    var spacing: CGFloat = 12
    /// Vertical space between rows (defaults to `spacing`).
    var rowSpacing: CGFloat?
    /// All rows as tall as the tallest card; otherwise each row as tall as its own tallest.
    var uniformRowHeights = true

    init(minimumItemWidth: CGFloat, maximumColumns: Int = .max, spacing: CGFloat = 12, rowSpacing: CGFloat? = nil, uniformRowHeights: Bool = true) {
        self.minimumItemWidth = minimumItemWidth
        self.maximumColumns = maximumColumns
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        self.uniformRowHeights = uniformRowHeights
    }

    // MARK: Arrangement

    /// How many cards fit side by side in `width`.
    static func columnsThatFit(width: CGFloat, minimumItemWidth: CGFloat, spacing: CGFloat, maximumColumns: Int) -> Int {
        guard width.isFinite, minimumItemWidth > 0 else { return max(1, min(maximumColumns, 3)) }
        let fit = Int(((width + spacing) / (minimumItemWidth + spacing)).rounded(.down))
        return max(1, min(maximumColumns, fit))
    }

    /// Lengths of the rows for `count` cards when at most `fit` fit in a row.
    static func rowLengths(count: Int, fitting fit: Int) -> [Int] {
        guard count > 0 else { return [] }
        let fit = max(1, fit)
        if count <= fit { return [count] }
        let balancedRows = Int((Double(count) / Double(fit)).rounded(.up))
        // Equal rows when that costs at most one extra row (9 → 3 × 3 rather than 5 + 4).
        if fit >= 2 {
            for columns in stride(from: fit, through: 2, by: -1) where count % columns == 0 && count / columns <= balancedRows + 1 {
                return Array(repeating: columns, count: count / columns)
            }
        }
        // Otherwise as even as possible, longer rows first (5 → 3 + 2, never 4 + 1).
        let base = count / balancedRows
        let extra = count % balancedRows
        return (0..<balancedRows).map { $0 < extra ? base + 1 : base }
    }

    private func rows(count: Int, width: CGFloat) -> [Int] {
        let fit = Self.columnsThatFit(width: width, minimumItemWidth: minimumItemWidth, spacing: spacing, maximumColumns: maximumColumns)
        return Self.rowLengths(count: count, fitting: fit)
    }

    private func itemWidth(rowLength: Int, width: CGFloat) -> CGFloat {
        max(0, (width - spacing * CGFloat(rowLength - 1)) / CGFloat(rowLength))
    }

    private func rowHeights(_ rows: [Int], width: CGFloat, subviews: Subviews) -> [CGFloat] {
        var heights: [CGFloat] = []
        var index = 0
        for length in rows {
            let itemWidth = itemWidth(rowLength: length, width: width)
            var tallest: CGFloat = 0
            for _ in 0..<length {
                tallest = max(tallest, subviews[index].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil)).height)
                index += 1
            }
            heights.append(tallest)
        }
        if uniformRowHeights, let tallest = heights.max() {
            return heights.map { _ in tallest }
        }
        return heights
    }

    // MARK: Layout

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            let columns = min(subviews.count, maximumColumns, 3)
            width = minimumItemWidth * CGFloat(columns) + spacing * CGFloat(columns - 1)
        }
        let rows = rows(count: subviews.count, width: width)
        let heights = rowHeights(rows, width: width, subviews: subviews)
        let height = heights.reduce(0, +) + (rowSpacing ?? spacing) * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let rows = rows(count: subviews.count, width: bounds.width)
        let heights = rowHeights(rows, width: bounds.width, subviews: subviews)
        var index = 0
        var y = bounds.minY
        for (row, length) in rows.enumerated() {
            let itemWidth = itemWidth(rowLength: length, width: bounds.width)
            var x = bounds.minX
            for _ in 0..<length {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: itemWidth, height: heights[row])
                )
                x += itemWidth + spacing
                index += 1
            }
            y += heights[row] + (rowSpacing ?? spacing)
        }
    }
}
