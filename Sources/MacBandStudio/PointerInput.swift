import SwiftUI
#if canImport(AppKit)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// Modifier keys, as the interactive views see them. On a Mac they are the keyboard's; on iOS the app's toolbar buttons stand in for them.
struct PointerModifiers: OptionSet {
    let rawValue: Int
    static let shift = PointerModifiers(rawValue: 1)
    static let option = PointerModifiers(rawValue: 2)
    static let control = PointerModifiers(rawValue: 4)
    static let command = PointerModifiers(rawValue: 8)
}

/// One mouse click or touch, in the coordinates of the view it happened in. The editing views take these, whether they came from
/// AppKit mouse events or from iOS touch gestures.
struct PointerEvent {
    var location: CGPoint
    var modifierFlags: PointerModifiers = []
    var clickCount = 1
}

/// One entry of a context menu (right-click on the Mac).
struct ContextAction {
    var title: String
    var destructive = false
    var run: () -> Void
}

#if canImport(AppKit)
extension PointerEvent {
    init(_ e: NSEvent, in view: NSView) {
        var m: PointerModifiers = []
        if e.modifierFlags.contains(.shift) { m.insert(.shift) }
        if e.modifierFlags.contains(.option) { m.insert(.option) }
        if e.modifierFlags.contains(.control) { m.insert(.control) }
        if e.modifierFlags.contains(.command) { m.insert(.command) }
        self.init(location: view.convert(e.locationInWindow, from: nil), modifierFlags: m, clickCount: e.clickCount)
    }
}

extension NSView {
    /// The layer behind this view (made on demand), the same name on both platforms.
    var hostLayer: CALayer { wantsLayer = true; return layer! }
}
#else
extension UIView {
    /// `needsDisplay = true` asks for a redraw, as on the Mac.
    var needsDisplay: Bool {
        get { false }
        set { if newValue { setNeedsDisplay() } }
    }
    var hostLayer: CALayer { layer }
}
#endif
