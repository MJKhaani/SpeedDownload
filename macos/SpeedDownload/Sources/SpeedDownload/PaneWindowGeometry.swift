import AppKit

/// The part of a panel's width added to each side of the existing window.
/// Keeping both values lets a later close reverse a boundary-constrained open.
struct PaneExtent: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    var width: CGFloat { left + right }
}

enum PaneWindowGeometry {
    enum Side { case left, right }

    static func expand(_ original: CGRect, by requested: CGFloat, toward side: Side,
                       in visible: CGRect, maximumWidth: CGFloat = .greatestFiniteMagnitude) -> (CGRect, PaneExtent) {
        guard requested > 0, visible.width > 0 else { return (original, PaneExtent()) }
        // A monitor change may leave the window partly outside the new visible frame.
        var frame = fitHorizontally(original, in: visible)
        let available = max(0, min(visible.width, maximumWidth) - frame.width)
        let amount = min(requested, available)
        let leftSpace = max(0, frame.minX - visible.minX)
        let rightSpace = max(0, visible.maxX - frame.maxX)
        let left: CGFloat
        let right: CGFloat
        switch side {
        case .left:
            left = min(amount, leftSpace)
            right = min(amount - left, rightSpace)
        case .right:
            right = min(amount, rightSpace)
            left = min(amount - right, leftSpace)
        }
        frame.origin.x -= left
        frame.size.width += left + right
        return (frame, PaneExtent(left: left, right: right))
    }

    static func collapse(_ frame: CGRect, removing extent: PaneExtent, minimumWidth: CGFloat) -> CGRect {
        guard extent.width > 0 else { return frame }
        var result = frame
        let removed = min(extent.width, max(0, frame.width - minimumWidth))
        result.origin.x += extent.left * removed / extent.width
        result.size.width -= removed
        return result
    }

    static func fitHorizontally(_ original: CGRect, in visible: CGRect) -> CGRect {
        guard visible.width > 0 else { return original }
        var frame = original
        frame.size.width = min(frame.width, visible.width)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        return frame
    }
}
