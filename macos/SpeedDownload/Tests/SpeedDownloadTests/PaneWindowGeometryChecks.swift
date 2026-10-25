import AppKit

@main
struct PaneWindowGeometryChecks {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let original = CGRect(x: 300, y: 100, width: 800, height: 600)
        let (sidebarFrame, sidebar) = PaneWindowGeometry.expand(original, by: 220, toward: .left, in: screen)
        precondition(sidebarFrame == CGRect(x: 80, y: 100, width: 1020, height: 600))
        precondition(PaneWindowGeometry.collapse(sidebarFrame, removing: sidebar, minimumWidth: 500) == original)

        let (inspectorFrame, inspector) = PaneWindowGeometry.expand(original, by: 280, toward: .right, in: screen)
        precondition(inspectorFrame == CGRect(x: 300, y: 100, width: 1080, height: 600))
        precondition(PaneWindowGeometry.collapse(inspectorFrame, removing: inspector, minimumWidth: 500) == original)

        var manuallyResized = inspectorFrame
        manuallyResized.size.width += 100
        let afterClose = PaneWindowGeometry.collapse(manuallyResized, removing: inspector, minimumWidth: 500)
        precondition(afterClose.width == original.width + 100)

        let edge = CGRect(x: 10, y: 100, width: 800, height: 600)
        let (edgeFrame, edgeExtent) = PaneWindowGeometry.expand(edge, by: 220, toward: .left, in: screen)
        precondition(edgeExtent == PaneExtent(left: 10, right: 210))
        precondition(PaneWindowGeometry.collapse(edgeFrame, removing: edgeExtent, minimumWidth: 500) == edge)

        let constrainedScreen = CGRect(x: 0, y: 0, width: 1000, height: 900)
        let (limitedFrame, limitedExtent) = PaneWindowGeometry.expand(edge, by: 320, toward: .right, in: constrainedScreen)
        precondition(limitedFrame.maxX <= constrainedScreen.maxX)
        precondition(limitedExtent.width == 200)
        precondition(PaneWindowGeometry.collapse(limitedFrame, removing: limitedExtent, minimumWidth: 500) == edge)

        let (both, rightExtent) = PaneWindowGeometry.expand(sidebarFrame, by: 280, toward: .right, in: screen)
        let withoutSidebar = PaneWindowGeometry.collapse(both, removing: sidebar, minimumWidth: 500)
        precondition(PaneWindowGeometry.collapse(withoutSidebar, removing: rightExtent, minimumWidth: 500) == original)
        print("Pane window geometry checks passed")
    }
}
