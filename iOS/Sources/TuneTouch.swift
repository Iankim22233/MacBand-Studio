import UIKit

/// A press-and-hold on a view shows its context menu (the right-click menu on the Mac).
func contextMenuConfiguration(_ actions: [ContextAction]) -> UIContextMenuConfiguration? {
    let real = actions.filter { $0.title != "-" }
    guard !real.isEmpty else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
        UIMenu(children: real.map { a in UIAction(title: a.title, attributes: a.destructive ? .destructive : []) { _ in a.run() } })
    }
}

extension TuneCanvas: UIContextMenuInteractionDelegate {
    /// One finger edits notes, markers and words like the mouse does, two fingers scroll, a pinch zooms; press and hold for the menu.
    func installTouchInput() {
        var h = TouchHandlers()
        h.down = { [weak self] in self?.pointerDown($0) }
        h.dragged = { [weak self] in self?.pointerDragged($0) }
        h.up = { [weak self] in self?.pointerUp($0) }
        h.scroll = { [weak self] dx, dy in self?.scrollBy(dx: dx, dy: dy) }
        h.pinch = { [weak self] f, _ in self?.zoom(by: f) }
        h.modifiers = { [weak self] in self?.session.touchModifiers ?? [] }
        touchController = TouchInputController(view: self, handlers: h)
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        contextMenuConfiguration(contextActions(at: location))
    }
}

extension TimelineView: UIContextMenuInteractionDelegate {
    func installContextMenu() { addInteraction(UIContextMenuInteraction(delegate: self)) }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        contextMenuConfiguration(contextActions(at: location))
    }
}
