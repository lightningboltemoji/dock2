import Foundation

/// How the sideline's puck holds its apps ([sideline](../../.agents/product/dock.md#the-sideline)): square
/// cells, each the main tile's slot cut into a whole number of parts, in rows filled from the bottom left.
public struct SidelinePacking: Sendable, Equatable, CustomStringConvertible {
    /// The main tile's slot divided by this; nil where half a slot holds less than the smallest icon, and the
    /// cells are that icon's.
    public let cut: Int?
    /// The side of a cell.
    public let cell: Double
    public let rows: Int
    public let columns: Int

    /// The smallest sidelined icon.
    public static let smallestIcon = 24.0

    /// The icon in a cell: the cell less the icon's own inset, as a tile is its slot less its inset.
    public var icon: Double { Self.icon(inSlot: cell) }

    /// The cells left empty, at the top right.
    public func empty(holding count: Int) -> Int { rows * columns - count }

    /// The `index`th app's cell, counted from the bottom left.
    public func place(of index: Int) -> (row: Int, column: Int) { (index / columns, index % columns) }

    public var description: String { "\(rows)×\(columns) of \(cut.map { "1/\($0)" } ?? "\(cell)pt")" }

    init(cut: Int?, cell: Double, rows: Int, columns: Int) {
        (self.cut, self.cell, self.rows, self.columns) = (cut, cell, rows, columns)
    }

    /// The rule for `count` apps beside tiles of `metrics`, nil for none: of the coarsest cut that holds them all
    /// in one tile's square and the next finer, the shape with the fewest empty cells, then the bigger cells, then
    /// more rows — never more rows than the cut, nor more columns unless the finest cut cannot hold them all.
    public init?(count: Int, metrics: DockMetrics) {
        guard count > 0 else { return nil }
        let slot = metrics.tileWidth
        let finest = Self.finestCut(slot: slot)
        guard finest >= 2 else {
            self = Self.row(count: count, metrics: metrics)
            return
        }
        let coarsest = max(2, (1...).first { $0 * $0 >= count }!)
        let cuts = coarsest > finest ? [finest] : [coarsest, coarsest + 1].filter { $0 <= finest }
        let widest = coarsest > finest ? (count + finest - 1) / finest : nil
        var best: (packing: SidelinePacking, rank: (Int, Int, Int))?
        for cut in cuts {
            for rows in 1...cut {
                for columns in 1...(widest ?? cut) where rows * columns >= count {
                    let rank = (rows * columns - count, cut, -rows)
                    guard best.map({ rank < $0.rank }) ?? true else { continue }
                    best = (SidelinePacking(cut: cut, cell: slot / Double(cut), rows: rows, columns: columns), rank)
                }
            }
        }
        self = best!.packing
    }

    /// Below tile size 48, half a slot holds less than the smallest icon: one row of those, or of icons the
    /// tiles' size if smaller, as long as it has to be.
    private static func row(count: Int, metrics: DockMetrics) -> SidelinePacking {
        let icon = min(smallestIcon, metrics.tileSize)
        return SidelinePacking(cut: nil, cell: DockMetrics(tileSize: icon).tileWidth, rows: 1, columns: count)
    }

    /// Finer cuts than this one, down to the smallest icon, each as narrow as it goes and with as few empty
    /// cells at that width, coarsest first: how the puck narrows when the dock does not fit the screen.
    public func finer(holding count: Int, metrics: DockMetrics) -> [SidelinePacking] {
        guard let cut else { return [] }
        let slot = metrics.tileWidth
        let finest = Self.finestCut(slot: slot)
        guard cut < finest else { return [] }
        return (cut + 1...finest).map { cut in
            let columns = (count + cut - 1) / cut
            return SidelinePacking(cut: cut, cell: slot / Double(cut), rows: (count + columns - 1) / columns, columns: columns)
        }
    }

    /// The most parts a slot `slot` wide is cut into while each cell's icon is still the smallest icon or more.
    static func finestCut(slot: Double) -> Int {
        var cut = 1
        while icon(inSlot: slot / Double(cut + 1)) >= smallestIcon - 1e-9 { cut += 1 }
        return cut
    }

    /// The icon a slot `width` wide holds: the width less the icon's inset either side, which grows with the
    /// icon (`DockMetrics.iconInset`); where no inset fits exactly, the larger, so the icon stays inside.
    static func icon(inSlot width: Double) -> Double {
        let insets = (1...3).map(Double.init)
        let fitting = insets.first { DockMetrics(tileSize: width - 2 * $0).iconInset <= $0 } ?? insets.last!
        return width - 2 * fitting
    }
}
