import SwiftUI

/// The island's outline: a rectangle with rounded bottom corners, plus concave "ears"
/// at the top that curve outward into the menu bar, like the hardware notch.
///
/// The rect passed in includes the ears, so the solid body is `rect.width - 2 * ear` wide.
nonisolated struct IslandShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat = Theme.earRadius

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Shrink the ears as the island gets very short (e.g. hidden on external displays).
        let e = max(0, min(ear, rect.height, rect.width / 4))
        let bodyWidth = rect.width - 2 * e
        let r = max(0, min(bottomRadius, rect.height - e, bodyWidth / 2))

        let left = rect.minX + e
        let right = rect.maxX - e

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.minY + e), radius: e)
        p.addLine(to: CGPoint(x: left, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: left + r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: right - r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: right, y: rect.minY + e))
        p.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: e)
        p.closeSubpath()
        return p
    }
}
