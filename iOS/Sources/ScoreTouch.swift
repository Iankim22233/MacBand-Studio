import UIKit

extension ScoreCanvas {
    /// One finger edits the score (the scroll view takes two fingers), and a pinch changes the size of the notation.
    func installTouchInput() {
        var h = TouchHandlers()
        h.down = { [weak self] in self?.pointerDown($0) }
        h.dragged = { [weak self] in self?.pointerDragged($0) }
        h.up = { [weak self] in self?.pointerUp($0) }
        h.pinch = { [weak self] f, _ in
            guard let self else { return }
            self.session.scoreZoom = min(2.0, max(0.6, self.session.scoreZoom * f))
        }
        h.modifiers = { [weak self] in self?.session.touchModifiers ?? [] }
        touchController = TouchInputController(view: self, handlers: h)
    }
}
