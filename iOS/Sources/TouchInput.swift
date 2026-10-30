import UIKit

/// What a view wants to do with touches: one finger edits (the same calls the Mac makes for mouse clicks), two fingers scroll,
/// a pinch zooms.
struct TouchHandlers {
    var down: (PointerEvent) -> Void = { _ in }
    var dragged: (PointerEvent) -> Void = { _ in }
    var up: (PointerEvent) -> Void = { _ in }
    /// Content should move by this many points (a two-finger drag, or a one-finger drag with the Hand tool).
    var scroll: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// A pinch: the factor since the last call, and where the fingers are.
    var pinch: (CGFloat, CGPoint) -> Void = { _, _ in }
    /// The modifier keys the toolbar toggles stand in for.
    var modifiers: () -> PointerModifiers = { [] }
    /// True while one finger should scroll instead of edit (the Hand tool).
    var oneFingerScrolls: () -> Bool = { false }
}

/// Follows one finger and reports it as a mouse would: down, dragged, up. A second finger landing cancels it, so a two-finger scroll
/// never draws or moves anything. The "down" is held back a few milliseconds for the same reason.
final class PointerRecognizer: UIGestureRecognizer {
    var handlers = TouchHandlers()
    var holdOff: TimeInterval = 0.06
    private var touch: UITouch?
    private var started = false
    private var timer: Timer?
    private var startLocation: CGPoint = .zero
    private var lastLocation: CGPoint = .zero
    private var clickCount = 1
    private var scrolling = false

    private func event(at p: CGPoint) -> PointerEvent { PointerEvent(location: p, modifierFlags: handlers.modifiers(), clickCount: clickCount) }

    private func fireDown() {
        guard touch != nil, !started else { return }
        timer?.invalidate(); timer = nil
        started = true
        scrolling = handlers.oneFingerScrolls()
        if !scrolling { handlers.down(event(at: startLocation)) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view else { return }
        if touch == nil, let t = touches.first, (event.touches(for: self)?.count ?? touches.count) == 1 {
            touch = t; started = false
            startLocation = t.location(in: view); lastLocation = startLocation
            clickCount = max(1, t.tapCount)
            state = .began
            timer = Timer.scheduledTimer(withTimeInterval: holdOff, repeats: false) { [weak self] _ in self?.fireDown() }
        } else {
            abort()                                     // a second finger: this is a scroll or a pinch, not an edit
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t), let view else { return }
        let p = t.location(in: view)
        if !started {
            if hypot(p.x - startLocation.x, p.y - startLocation.y) > 5 { fireDown() } else { return }
        }
        if scrolling { handlers.scroll(p.x - lastLocation.x, p.y - lastLocation.y) }
        else { handlers.dragged(self.event(at: p)) }
        lastLocation = p
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t), let view else { return }
        let p = t.location(in: view)
        if !started { fireDown() }
        if started && !scrolling { handlers.up(self.event(at: p)) }
        clear(); state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touch, touches.contains(t) else { return }
        abort()
    }

    private func abort() {
        if started && !scrolling { handlers.up(event(at: lastLocation)) }
        clear(); state = .cancelled
    }

    private func clear() {
        timer?.invalidate(); timer = nil
        touch = nil; started = false; scrolling = false
    }

    override func reset() { clear() }
}

/// Installs the recognizers on a view and keeps the two-finger gestures going after a one-finger edit was cancelled.
final class TouchInputController: NSObject, UIGestureRecognizerDelegate {
    let pointer = PointerRecognizer()
    private let pan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private var handlers: TouchHandlers
    private weak var view: UIView?
    private var link: CADisplayLink?
    private var velocity = CGPoint.zero

    init(view: UIView, handlers: TouchHandlers) {
        self.handlers = handlers
        self.view = view
        super.init()
        pointer.handlers = handlers
        pointer.delegate = self
        pan.minimumNumberOfTouches = 2; pan.maximumNumberOfTouches = 2
        pan.addTarget(self, action: #selector(panned(_:))); pan.delegate = self
        pinch.addTarget(self, action: #selector(pinched(_:))); pinch.delegate = self
        view.addGestureRecognizer(pointer); view.addGestureRecognizer(pan); view.addGestureRecognizer(pinch)
        view.isMultipleTouchEnabled = true
    }

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began: stopGlide()
        case .changed:
            let t = g.translation(in: view)
            handlers.scroll(t.x, t.y)
            g.setTranslation(.zero, in: view)
        case .ended:
            velocity = g.velocity(in: view)
            startGlide()
        default: break
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed, let view else { return }
        handlers.pinch(g.scale, g.location(in: view))
        g.scale = 1
    }

    /// A short glide after the fingers lift, like any scrolling list.
    private func startGlide() {
        guard hypot(velocity.x, velocity.y) > 120 else { return }
        link?.invalidate()
        link = CADisplayLink(target: self, selector: #selector(glide(_:)))
        link?.add(to: .main, forMode: .common)
    }
    private func stopGlide() { link?.invalidate(); link = nil }
    @objc private func glide(_ l: CADisplayLink) {
        let dt = CGFloat(l.duration)
        handlers.scroll(velocity.x * dt, velocity.y * dt)
        let decay = pow(0.06, dt)                       // loses most of its speed in about a second
        velocity = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        if hypot(velocity.x, velocity.y) < 25 { stopGlide() }
    }
}
