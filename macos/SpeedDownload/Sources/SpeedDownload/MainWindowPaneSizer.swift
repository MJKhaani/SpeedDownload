import AppKit
import SwiftUI
import QuartzCore

struct SidebarWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

struct InspectorWidthPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Observes only the window that owns this dashboard. Its coordinator keeps
/// the width actually gained by each panel, so screen-edge clipping is undone
/// exactly when that panel closes.
struct MainWindowPaneSizer: NSViewRepresentable {
    let sidebarVisible: Bool
    let inspectorVisible: Bool
    let sidebarWidth: CGFloat
    let inspectorWidth: CGFloat
    let restoredSidebarVisible: Bool
    let restoredInspectorVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView(frame: .zero)
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
            coordinator?.reconcile()
        }
        return view
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        context.coordinator.sidebarVisible = sidebarVisible
        context.coordinator.inspectorVisible = inspectorVisible
        context.coordinator.sidebarWidth = sidebarWidth
        context.coordinator.inspectorWidth = inspectorWidth
        context.coordinator.restoredSidebarVisible = restoredSidebarVisible
        context.coordinator.restoredInspectorVisible = restoredInspectorVisible
        context.coordinator.attach(to: view.window)
        context.coordinator.reconcile()
    }

    final class WindowProbeView: NSView {
        var windowChanged: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowChanged?(window)
        }
    }

    final class Coordinator {
        weak var window: NSWindow?
        var sidebarVisible = false
        var inspectorVisible = false
        var sidebarWidth: CGFloat = 220
        var inspectorWidth: CGFloat = 320
        var restoredSidebarVisible = false
        var restoredInspectorVisible = false
        private var previous: (sidebar: Bool, inspector: Bool)?
        private var sidebarExtent = PaneExtent()
        private var inspectorExtent = PaneExtent()
        private var appliedSidebarWidth: CGFloat = 220
        private var appliedInspectorWidth: CGFloat = 320
        private var lastTarget: CGRect?
        private var lastAdjustmentTime: TimeInterval = 0
        private var lastScreenFrame: CGRect?
        private var observers: [NSObjectProtocol] = []

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        func attach(to newWindow: NSWindow?) {
            guard window !== newWindow else { return }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            window = newWindow
            lastTarget = nil
            lastAdjustmentTime = 0
            lastScreenFrame = nil
            guard let newWindow else { return }
            for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didChangeScreenNotification,
                         NSWindow.didDeminiaturizeNotification] {
                let observer = NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                    self?.lastTarget = nil
                    self?.lastAdjustmentTime = 0
                    self?.reconcile()
                }
                observers.append(observer)
            }
        }

        func reconcile() {
            guard let window else { return }
            let initialTransition = previous == nil
            if previous == nil {
                previous = (restoredSidebarVisible, restoredInspectorVisible)
                // The restored frame already includes panels that were visible
                // when the window closed. New panels still need an expansion.
                sidebarExtent = restoredSidebarVisible ? PaneExtent(left: sidebarWidth) : PaneExtent()
                inspectorExtent = restoredInspectorVisible ? PaneExtent(right: inspectorWidth) : PaneExtent()
                appliedSidebarWidth = sidebarWidth
                appliedInspectorWidth = inspectorWidth
                if restoredSidebarVisible == sidebarVisible && restoredInspectorVisible == inspectorVisible { return }
            }
            let old = self.previous!
            let sidebarWidthChanged = sidebarVisible && abs(sidebarWidth - appliedSidebarWidth) > 3
            let inspectorWidthChanged = inspectorVisible && abs(inspectorWidth - appliedInspectorWidth) > 3
            guard old.sidebar != sidebarVisible || old.inspector != inspectorVisible ||
                    sidebarWidthChanged || inspectorWidthChanged else { return }
            // Keep this transition pending until the user's resize gesture ends.
            guard !window.inLiveResize else { return }
            self.previous = (sidebarVisible, inspectorVisible)

            // Fullscreen, zoomed, tiled/full-display, and miniaturized windows
            // keep the system-managed frame. SwiftUI still presents both panes.
            guard let screen = window.screen,
                  !window.styleMask.contains(.fullScreen), !window.isZoomed,
                  !window.isMiniaturized else {
                sidebarExtent = PaneExtent()
                inspectorExtent = PaneExtent()
                appliedSidebarWidth = sidebarWidth
                appliedInspectorWidth = inspectorWidth
                lastTarget = nil
                return
            }
            let visible = screen.visibleFrame
            guard visible.width > 0 else { return }
            if lastScreenFrame != visible {
                lastTarget = nil
                lastAdjustmentTime = 0
                lastScreenFrame = visible
            }
            let current = window.frame
            let fillsScreenHeight = abs(current.minY - visible.minY) < 8 && abs(current.height - visible.height) < 8
            let alignedToScreenEdge = abs(current.minX - visible.minX) < 8 || abs(current.maxX - visible.maxX) < 8
            if fillsScreenHeight && alignedToScreenEdge {
                sidebarExtent = PaneExtent()
                inspectorExtent = PaneExtent()
                appliedSidebarWidth = sidebarWidth
                appliedInspectorWidth = inspectorWidth
                lastTarget = nil
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            var target = now - lastAdjustmentTime < 0.35 ? (lastTarget ?? current) : current
            let minimum = window.minSize.width
            let maximum = window.maxSize.width

            // Remove old extents before adding new ones. This also handles
            // simultaneous toggles without accumulating independent deltas.
            if old.sidebar && !sidebarVisible {
                target = PaneWindowGeometry.collapse(target, removing: sidebarExtent, minimumWidth: minimum)
                sidebarExtent = PaneExtent()
            }
            if old.inspector && !inspectorVisible {
                target = PaneWindowGeometry.collapse(target, removing: inspectorExtent, minimumWidth: minimum)
                inspectorExtent = PaneExtent()
            }
            if !old.sidebar && sidebarVisible {
                (target, sidebarExtent) = PaneWindowGeometry.expand(target, by: sidebarWidth, toward: .left,
                                                                    in: visible, maximumWidth: maximum)
                appliedSidebarWidth = sidebarWidth
            }
            if !old.inspector && inspectorVisible {
                (target, inspectorExtent) = PaneWindowGeometry.expand(target, by: inspectorWidth, toward: .right,
                                                                      in: visible, maximumWidth: maximum)
                appliedInspectorWidth = inspectorWidth
            }
            if old.sidebar && sidebarVisible && sidebarWidthChanged {
                adjust(&target, extent: &sidebarExtent, from: appliedSidebarWidth,
                       to: sidebarWidth, toward: .left, in: visible, minimum: minimum, maximum: maximum)
                appliedSidebarWidth = sidebarWidth
            }
            if old.inspector && inspectorVisible && inspectorWidthChanged {
                adjust(&target, extent: &inspectorExtent, from: appliedInspectorWidth,
                       to: inspectorWidth, toward: .right, in: visible, minimum: minimum, maximum: maximum)
                appliedInspectorWidth = inspectorWidth
            }
            target = PaneWindowGeometry.fitHorizontally(target, in: visible)
            guard target != current else { return }
            lastTarget = target
            lastAdjustmentTime = now
            if initialTransition || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                window.setFrame(target, display: true, animate: false)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(target, display: true)
                }
            }
        }

        private func adjust(_ frame: inout CGRect, extent: inout PaneExtent, from oldWidth: CGFloat,
                            to newWidth: CGFloat, toward side: PaneWindowGeometry.Side,
                            in visible: CGRect, minimum: CGFloat, maximum: CGFloat) {
            let difference = newWidth - oldWidth
            if difference > 0 {
                let (expanded, added) = PaneWindowGeometry.expand(frame, by: difference, toward: side,
                                                                   in: visible, maximumWidth: maximum)
                frame = expanded
                extent.left += added.left
                extent.right += added.right
            } else if difference < 0, extent.width > 0 {
                let fraction = min(1, -difference / extent.width)
                let removed = PaneExtent(left: extent.left * fraction, right: extent.right * fraction)
                let oldFrame = frame
                frame = PaneWindowGeometry.collapse(frame, removing: removed, minimumWidth: minimum)
                let applied = oldFrame.width - frame.width
                let ratio = removed.width > 0 ? applied / removed.width : 0
                extent.left -= removed.left * ratio
                extent.right -= removed.right * ratio
            }
        }
    }
}

struct PaneSizingModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let columnVisibility: NavigationSplitViewVisibility
    let showingInspector: Bool
    @Binding var sidebarWidth: CGFloat
    @Binding var inspectorWidth: CGFloat
    let restoredSidebarVisible: Bool
    let restoredInspectorVisible: Bool

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: columnVisibility)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showingInspector)
            .background(MainWindowPaneSizer(sidebarVisible: columnVisibility != .detailOnly,
                                            inspectorVisible: showingInspector,
                                            sidebarWidth: sidebarWidth, inspectorWidth: inspectorWidth,
                                            restoredSidebarVisible: restoredSidebarVisible,
                                            restoredInspectorVisible: restoredInspectorVisible))
            .onPreferenceChange(SidebarWidthPreference.self) { width in
                if width > 1 {
                    sidebarWidth = width
                    UserDefaults.standard.set(Double(width), forKey: "dashboardSidebarWidth")
                }
            }
            .onPreferenceChange(InspectorWidthPreference.self) { width in
                if width > 1 {
                    inspectorWidth = width
                    UserDefaults.standard.set(Double(width), forKey: "dashboardInspectorWidth")
                }
            }
    }
}
