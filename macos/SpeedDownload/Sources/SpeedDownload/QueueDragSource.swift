import AppKit
import SwiftUI

/// A small native drag source so releasing a queue outside its window can be
/// distinguished from an ordinary click. The main queue never installs it.
struct QueueDragSource: NSViewRepresentable {
    let name: String
    let select: () -> Void
    let remove: () -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        view.select = select
        view.remove = remove
        view.name = name
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.select = select
        view.remove = remove
        view.name = name
    }

    final class DragView: NSView, NSDraggingSource {
        var name = ""
        var select: (() -> Void)?
        var remove: (() -> Void)?
        private var beganDrag = false
        private var origin: NSPoint = .zero

        override func mouseDown(with event: NSEvent) {
            origin = convert(event.locationInWindow, from: nil)
            beganDrag = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !beganDrag else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - origin.x, point.y - origin.y) > 5 else { return }
            beganDrag = true
            let item = NSDraggingItem(pasteboardWriter: name as NSString)
            let image = NSImage(size: NSSize(width: max(bounds.width, 110), height: 24))
            image.lockFocus()
            (name as NSString).draw(at: NSPoint(x: 8, y: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            image.unlockFocus()
            item.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            if !beganDrag { select?() }
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard let window, !window.frame.contains(screenPoint) else { return }
            remove?()
        }
    }
}
