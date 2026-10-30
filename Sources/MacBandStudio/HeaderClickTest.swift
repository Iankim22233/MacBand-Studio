import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// `--headertest`: buttons above and beside the track list must still be clickable after the list has been scrolled.
@MainActor
enum HeaderClickTest {
    static var failures = 0
    static func check(_ ok: Bool, _ m: String) { print(ok ? "  ok    \(m)" : "  FAIL  \(m)"); if !ok { failures += 1 } }

    final class Counter: ObservableObject { @Published var top = 0 }

    static func find(_ v: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(v) { return v }
        for sub in v.subviews { if let f = find(sub, where: match) { return f } }
        return nil
    }
    static func isInside(_ v: NSView?, _ container: NSView) -> Bool {
        var cur = v
        while let c = cur { if c === container { return true }; cur = c.superview }
        return false
    }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Track list scrolling vs buttons test ==")
        let s = Session()
        var p = DemoSong.make()
        let first = p.tracks
        for i in 0..<9 { var t = first[i % first.count]; t.id = UUID(); t.name = "Track \(i + 4)"; p.tracks.append(t) }
        s.project = p
        let state = ArrangementState()
        state.rowH = 100
        let counter = Counter()
        let topH: CGFloat = 60
        let root = VStack(spacing: 0) {
            HStack { Button("Top") { counter.top += 1 }.buttonStyle(.plain).frame(width: 120, height: 40).background(Color.red); Spacer() }
                .frame(height: topH).background(Color.black)
            HStack(spacing: 0) {
                TrackHeaderColumn(state: state).frame(width: 214)
                Color.gray.frame(width: 400)
            }
        }.environmentObject(s).frame(width: 640, height: 640)
        let win = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = NSHostingView(rootView: root)
        win.makeKeyAndOrderFront(nil)
        SelfTest.pump(0.6)

        guard let container = find(win.contentView!, where: { String(describing: type(of: $0)) == "Container" }) else {
            check(false, "the clipped track list is in the window"); return 1
        }
        let content = win.contentView!
        func hit(_ x: CGFloat, _ y: CGFloat) -> NSView? { content.hitTest(NSPoint(x: x, y: content.bounds.height - y)) }   // from the top-left
        // sample every point of the top bar and the track header, at and between the buttons
        func leaks(_ label: String) {
            var bad: [String] = []
            for y in stride(from: 4.0, to: Double(topH + state.headerH) - 2, by: 6.0) {
                for x in stride(from: 4.0, to: 210.0, by: 10.0) where isInside(hit(CGFloat(x), CGFloat(y)), container) { bad.append("(\(Int(x)),\(Int(y)))") }
            }
            check(bad.isEmpty, "\(label): no track row takes clicks meant for the buttons above the list \(bad.prefix(4).joined(separator: " "))")
        }
        let listTop = topH + state.headerH
        leaks("not scrolled")
        check(isInside(hit(60, listTop + 40), container), "not scrolled: a row under the pointer gets the click")
        state.scrollY = 380; SelfTest.pump(0.4)
        leaks("scrolled down")
        check(isInside(hit(60, listTop + 40), container), "scrolled down: the list still takes clicks inside its own area")
        check(container.subviews.first.map { $0.frame.origin.y == -380 } ?? false, "the rows are moved up by the scroll amount")
        state.scrollY = 0; SelfTest.pump(0.2)
        print(failures == 0 ? "ALL HEADER CLICK CHECKS PASSED" : "\(failures) HEADER CLICK CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
