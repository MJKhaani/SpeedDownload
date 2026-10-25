import AppKit
import SwiftUI

/// A small native drag source so releasing a queue outside its window can be
/// distinguished from an ordinary click. The main queue never installs it.
struct QueueDragSource: NSViewRepresentable {
    let name: String
    let select: () -> Void
    let remove: () -> Void
    var rename: (() -> Void)? = nil

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.select = select
        view.remove = remove
        view.rename = rename
        view.name = name
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.select = select
        view.remove = remove
        view.rename = rename
        view.name = name
    }

    final class DragView: NSView, NSDraggingSource {
        var name = ""
        var select: (() -> Void)?
        var remove: (() -> Void)?
        var rename: (() -> Void)?
        private var dragItem: NSDraggingItem?
        private var outside = false
        private var beganDrag = false
        private var origin: NSPoint = .zero

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2, let rename {
                rename()
                beganDrag = false
                return
            }
            origin = convert(event.locationInWindow, from: nil)
            beganDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !beganDrag else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - origin.x, point.y - origin.y) > 5 else { return }
            beganDrag = true
            let item = NSDraggingItem(pasteboardWriter: name as NSString)
            let image = dragImage(removing: false)
            item.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
            dragItem = item
            outside = false
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if !beganDrag && event.clickCount == 1 { select?() }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .delete : .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            defer { dragItem = nil }
            guard let window, !window.frame.contains(screenPoint) else { return }
            remove?()
        }

        func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
            let removing = !(window?.frame.contains(screenPoint) ?? true)
            guard removing != outside, let dragItem else { return }
            outside = removing
            let image = dragImage(removing: removing)
            dragItem.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
        }

        private func dragImage(removing: Bool) -> NSImage {
            let image = NSImage(size: NSSize(width: max(bounds.width, 150), height: 26))
            image.lockFocus()
            if removing {
                NSColor.systemRed.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: NSRect(origin: .zero, size: image.size), xRadius: 6, yRadius: 6).fill()
                NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove")?.draw(in: NSRect(x: 6, y: 5, width: 16, height: 16))
            }
            (name as NSString).draw(at: NSPoint(x: removing ? 27 : 8, y: 5), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: removing ? NSColor.white : NSColor.labelColor
            ])
            image.unlockFocus()
            return image
        }
    }
}
