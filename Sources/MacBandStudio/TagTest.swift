#if os(macOS)
import Foundation
import AppKit

/// `--tagtest`: placing, dragging, resizing, naming and deleting tags on the timeline, and keeping them with the project.
@MainActor
enum TagTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { print((ok ? "PASS " : "FAIL ") + what); if !ok { failures += 1 } }

    static func run() -> Int32 {
        _ = NSApplication.shared
        print("== Tags test ==")
        let s = Session()
        s.project = DemoSong.make()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let a = ArrangementState()
        let tl = TimelineView(session: s, state: a)
        tl.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
        win.contentView!.addSubview(tl)
        win.contentView!.layoutSubtreeIfNeeded()
        let ppb = a.ppb
        let laneY = ArrangementState.rulerH + ArrangementState.tagH / 2
        func px(_ beat: Double) -> CGFloat { CGFloat(beat) * ppb - a.scrollX * ppb }
        func tags() -> [Tag] { s.project.tags }
        check(ArrangementState.tempoTop == ArrangementState.rulerH + ArrangementState.tagH && a.headerH == ArrangementState.tempoTop + ArrangementState.tempoH, "the tag lane sits between the ruler and the tempo lane")

        // a click on the empty lane marks a spot and asks for its name
        UITest.click(tl, CGPoint(x: px(8), y: laneY))
        check(tags().count == 1 && tags()[0].start == 8 && tags()[0].length == 0, "clicking the lane places a tag on that spot")
        check(s.renamingTagID == tags().first?.id && s.selectedTagID == tags().first?.id, "a new tag is selected and asks for its name")
        s.renameTag(tags()[0].id, to: "  Chorus ")
        check(tags()[0].name == "Chorus", "naming it trims the name")
        s.renameTag(tags()[0].id, to: "   ")
        check(tags()[0].name == "Chorus", "an empty name is ignored")
        s.undo(); s.undo()
        check(tags().isEmpty, "undo takes the tag away again")
        s.redo(); s.redo()
        check(tags().count == 1 && tags()[0].name == "Chorus", "redo brings it back")

        // dragging along the lane marks an area
        UITest.drag(tl, from: CGPoint(x: px(16), y: laneY), to: CGPoint(x: px(24), y: laneY))
        check(tags().count == 2, "a second tag is added")
        let area = tags().first { $0.start == 16 }
        check(area != nil && abs((area?.length ?? 0) - 8) < 0.3, "dragging marks an area (16 → 24: \(area?.start ?? -1), length \(area?.length ?? -1))")
        check(tags().map { $0.start } == [8, 16], "tags stay in order of position")

        // clicking a tag takes the playhead to it; dragging it moves it
        s.seek(to: 0)
        UITest.click(tl, CGPoint(x: px(18), y: laneY))
        check(abs(s.transport.beat - 16) < 1e-6 && s.selectedTagID == area?.id, "clicking a tag moves the playhead to its start and selects it")
        UITest.drag(tl, from: CGPoint(x: px(18), y: laneY), to: CGPoint(x: px(22), y: laneY))
        let moved = tags().first { $0.id == area?.id }
        check(moved != nil && abs(moved!.start - 20) < 0.3 && abs(moved!.length - 8) < 1e-6, "dragging a tag moves it and keeps its length (now \(moved?.start ?? -1))")
        // dragging its end resizes it
        let e = moved!.end
        UITest.drag(tl, from: CGPoint(x: px(e) - 1, y: laneY), to: CGPoint(x: px(e + 3) - 1, y: laneY))
        let grown = tags().first { $0.id == area?.id }!
        check(abs(grown.start - 20) < 0.3 && abs(grown.length - 11) < 0.5, "dragging the end of an area stretches it (length \(grown.length))")
        UITest.drag(tl, from: CGPoint(x: px(grown.start) + 1, y: laneY), to: CGPoint(x: px(grown.start - 2) + 1, y: laneY))
        let earlier = tags().first { $0.id == area?.id }!
        check(abs(earlier.start - 18) < 0.5 && abs(earlier.end - grown.end) < 0.3, "dragging the start edge moves only the start")

        // double-click asks for a new name
        s.renamingTagID = nil
        UITest.click(tl, CGPoint(x: px(earlier.start + 2), y: laneY), clicks: 2)
        check(s.renamingTagID == earlier.id, "double-clicking a tag asks for its name")
        s.renamingTagID = nil

        // the menu
        let titles = tl.contextActions(at: CGPoint(x: px(earlier.start + 2), y: laneY)).map { $0.title }
        check(titles.contains("Rename Tag…") && titles.contains("Loop This Area") && titles.contains("Delete Tag") && titles.contains("Next Colour"), "right-click on a tag offers rename, colour, loop and delete")
        let empty = tl.contextActions(at: CGPoint(x: px(40), y: laneY)).map { $0.title }
        check(empty.contains("Add Tag Here"), "right-click on the empty lane offers Add Tag Here")
        tl.contextActions(at: CGPoint(x: px(earlier.start + 2), y: laneY)).first { $0.title == "Loop This Area" }?.run()
        check(abs(s.project.loopStart - earlier.start) < 1e-6 && abs(s.project.loopEnd - earlier.end) < 1e-6 && s.project.loopEnabled, "Loop This Area loops exactly what the tag covers")
        let c0 = earlier.colorIndex
        tl.contextActions(at: CGPoint(x: px(earlier.start + 2), y: laneY)).first { $0.title == "Next Colour" }?.run()
        check(tags().first { $0.id == earlier.id }?.colorIndex == (c0 + 1) % Palette.trackColors.count, "Next Colour changes the colour")

        // jumping between tags
        s.seek(to: 0); s.jumpToTag(forward: true)
        check(s.transport.beat == 8, "Next Tag goes to the first tag")
        s.jumpToTag(forward: true)
        check(abs(s.transport.beat - earlier.start) < 1e-6, "and on to the next")
        s.jumpToTag(forward: false)
        check(s.transport.beat == 8, "Previous Tag goes back")

        // the playhead tag key and the loop-area tag
        let before = tags().count
        s.seek(to: 30); s.addTag(start: s.transport.beat, ask: false)
        check(tags().count == before + 1 && tags().contains { $0.start == 30 }, "a tag can be put at the playhead")
        s.tagLoopArea()
        check(tags().contains { abs($0.start - s.project.loopStart) < 1e-6 && abs($0.length - (s.project.loopEnd - s.project.loopStart)) < 1e-6 }, "the loop area can be tagged")

        // clicking in the track area never makes tags, and unselects the tag
        let n = tags().count
        UITest.click(tl, CGPoint(x: px(50), y: a.headerH + a.rowH * 1.5))
        check(tags().count == n && s.selectedTagID == nil, "clicking among the tracks doesn't place tags and unselects the tag")

        // Delete removes the selected tag
        let victim = tags()[0].id
        s.selectedTagID = victim; s.selectedClipID = nil; s.selectedAudioClipID = nil
        win.makeFirstResponder(tl)
        UITest.key(tl, String(UnicodeScalar(127)), code: 51)
        check(!tags().contains { $0.id == victim }, "Delete removes the selected tag")
        s.clearTags()
        check(tags().isEmpty, "Clear All Tags empties the lane")

        // saving
        s.project.tags = [Tag(name: "Verse", start: 4), Tag(name: "Solo", start: 12, length: 8, colorIndex: 2)]
        let enc = try! JSONEncoder().encode(s.project)
        let back = try! JSONDecoder().decode(Project.self, from: enc)
        check(back.tags == s.project.tags, "tags are kept when the project is saved and opened")
        var legacy = (try! JSONSerialization.jsonObject(with: enc)) as! [String: Any]
        legacy.removeValue(forKey: "tags")
        let old = try? JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(old != nil && old!.tags.isEmpty, "projects saved before tags existed still open")
        // MIDI export
        let smf = [UInt8](MIDIFile.build(s.project, forExport: true))
        func has(_ name: String) -> Bool {
            let pat: [UInt8] = [0xFF, 0x06, UInt8(name.utf8.count)] + Array(name.utf8)
            return smf.indices.contains { i in i + pat.count <= smf.count && Array(smf[i..<(i + pat.count)]) == pat }
        }
        check(has("Verse") && has("Solo"), "exported MIDI files carry the tags as markers")

        print(failures == 0 ? "ALL TAG CHECKS PASSED" : "\(failures) TAG CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }
}
#endif
