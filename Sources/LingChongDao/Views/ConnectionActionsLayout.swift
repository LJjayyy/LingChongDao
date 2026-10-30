import SwiftUI

/// One set of controls, measured once per content change. Using alternative
/// HStack/VStack trees here makes the workbench repeatedly size both candidates
/// while its sidebar and scroll view negotiate their widths during navigation.
struct ConnectionActionsLayout: Layout {
    var spacing: CGFloat = 10

    struct Cache {
        var idealSizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(idealSizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let idealWidth = cache.idealSizes.reduce(0) { $0 + $1.width }
            + spacing * CGFloat(max(0, subviews.count - 1))
        let width = max(0, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? idealWidth)
        return arrangement(width: width, subviews: subviews, cache: cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let result = arrangement(width: bounds.width, subviews: subviews, cache: cache)
        for (index, item) in result.items.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: item.size.width, height: item.size.height))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews, cache: Cache) -> (size: CGSize, items: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var items: [CGRect] = []
        for (index, idealSize) in cache.idealSizes.enumerated() {
            let size = idealSize.width <= width ? idealSize
                : subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            // The final child contains the detail/delete controls. Keep it at
            // the trailing edge, whether it fits the current row or wraps.
            let itemX = index == subviews.count - 1 ? max(x, width - size.width) : x
            items.append(CGRect(origin: CGPoint(x: itemX, y: y), size: size))
            x = itemX + size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), items)
    }
}
