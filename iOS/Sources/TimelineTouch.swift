import UIKit

extension TimelineView {
    /// Touch for the arrangement: one finger does what the mouse does (select, move, resize, draw the loop, edit the tempo lane),
    /// two fingers scroll, a pinch zooms.
    func installTouchInput() {
        var h = TouchHandlers()
        h.down = { [weak self] in self?.pointerDown($0) }
        h.dragged = { [weak self] in self?.pointerDragged($0) }
        h.up = { [weak self] in self?.pointerUp($0) }
        h.scroll = { [weak self] dx, dy in self?.scrollBy(dx: dx, dy: dy, bothAxes: true) }
        h.pinch = { [weak self] f, p in self?.zoom(by: f, anchorX: p.x) }
        h.modifiers = { [weak self] in self?.session.touchModifiers ?? [] }
        touchController = TouchInputController(view: self, handlers: h)
        installContextMenu()
    }
}
