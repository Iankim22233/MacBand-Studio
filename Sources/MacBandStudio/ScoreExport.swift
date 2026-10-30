import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

// MARK: - MusicXML

enum MusicXML {
    static let divisions = 8                                  // per quarter note, so a 32nd note is 1
    private static let typeNames = ["whole", "half", "quarter", "eighth", "16th", "32nd"]
    private static let stepNames = ["C", "D", "E", "F", "G", "A", "B"]

    private static func dur(_ beats: Double) -> Int { Int((beats * Double(divisions)).rounded()) }
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func build(score: NScore, title: String, partName: String, tempo: Double, firstMeasure: Int = 1) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 3.1 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n"
        x += "<score-partwise version=\"3.1\">\n<work><work-title>\(esc(title))</work-title></work>\n"
        x += "<identification><encoding><software>MacBand Studio</software></encoding></identification>\n"
        x += "<part-list><score-part id=\"P1\"><part-name>\(esc(partName))</part-name></score-part></part-list>\n<part id=\"P1\">\n"
        let barDur = dur(score.beatsPerBar)
        for m in 0..<score.measureCount {
            x += "<measure number=\"\(m + firstMeasure)\">\n"
            if m == 0 {
                x += "<attributes><divisions>\(divisions)</divisions><key><fifths>\(score.fifths)</fifths></key>"
                x += "<time><beats>\(score.timeNum)</beats><beat-type>\(score.timeDen)</beat-type></time>"
                if score.staves.count > 1 { x += "<staves>\(score.staves.count)</staves>" }
                for (i, st) in score.staves.enumerated() {
                    let n = score.staves.count > 1 ? " number=\"\(i + 1)\"" : ""
                    switch st.clef {
                    case .treble: x += "<clef\(n)><sign>G</sign><line>2</line></clef>"
                    case .bass: x += "<clef\(n)><sign>F</sign><line>4</line></clef>"
                    case .percussion: x += "<clef\(n)><sign>percussion</sign><line>2</line></clef>"
                    }
                }
                x += "</attributes>\n"
                x += "<direction placement=\"above\"><direction-type><metronome><beat-unit>quarter</beat-unit><per-minute>\(Int(tempo.rounded()))</per-minute></metronome></direction-type><sound tempo=\"\(Int(tempo.rounded()))\"/></direction>\n"
            }
            var sequences: [(staff: Int, voice: Int, events: [NEvent])] = []
            for (si, st) in score.staves.enumerated() {
                let inMeasure = st.events.filter { $0.measure == m }
                for v in Set(inMeasure.map { $0.voice }).sorted() {
                    sequences.append((si, v, inMeasure.filter { $0.voice == v }.sorted { $0.start < $1.start }))
                }
            }
            for (k, seq) in sequences.enumerated() {
                let st = score.staves[seq.staff]
                var cursor = 0
                let voiceNo = seq.staff * 2 + seq.voice + 1
                for e in seq.events {
                    let start = dur(e.start - Double(m) * score.beatsPerBar)
                    if start > cursor { x += "<forward><duration>\(start - cursor)</duration></forward>\n" }
                    x += noteXML(e, staff: seq.staff, staffCount: score.staves.count, voice: voiceNo, clef: st.clef, barDur: barDur)
                    cursor = start + (e.fullBar ? barDur : dur(e.dur))
                }
                if cursor < barDur { x += "<forward><duration>\(barDur - cursor)</duration></forward>\n" }
                if k < sequences.count - 1 { x += "<backup><duration>\(barDur)</duration></backup>\n" }
            }
            x += "</measure>\n"
        }
        x += "</part>\n</score-partwise>\n"
        return x
    }

    private static func noteXML(_ e: NEvent, staff: Int, staffCount: Int, voice: Int, clef: Clef, barDur: Int) -> String {
        let d = e.fullBar ? barDur : dur(e.dur)
        let type = typeNames[min(5, max(0, e.base))]
        let staffTag = staffCount > 1 ? "<staff>\(staff + 1)</staff>" : ""
        if e.isRest {
            var s = "<note>\(e.fullBar ? "<rest measure=\"yes\"/>" : "<rest/>")<duration>\(d)</duration><voice>\(voice)</voice>"
            if !e.fullBar { s += "<type>\(type)</type>" + String(repeating: "<dot/>", count: e.dots) }
            return s + staffTag + "</note>\n"
        }
        var out = ""
        for (i, p) in e.pitches.enumerated() {
            var s = "<note>"
            if i > 0 { s += "<chord/>" }
            let letter = stepNames[((p.step % 7) + 7) % 7], oct = p.step / 7
            if clef == .percussion { s += "<unpitched><display-step>\(letter)</display-step><display-octave>\(oct)</display-octave></unpitched>" }
            else { s += "<pitch><step>\(letter)</step>" + (p.acc != 0 ? "<alter>\(p.acc)</alter>" : "") + "<octave>\(oct)</octave></pitch>" }
            s += "<duration>\(d)</duration>"
            if p.tiePrev { s += "<tie type=\"stop\"/>" }
            if p.tieNext { s += "<tie type=\"start\"/>" }
            s += "<voice>\(voice)</voice><type>\(type)</type>" + String(repeating: "<dot/>", count: e.dots)
            if e.base != 0 { s += "<stem>\(e.stemUp ? "up" : "down")</stem>" }
            if p.head == .x { s += "<notehead>x</notehead>" } else if p.head == .diamond { s += "<notehead>diamond</notehead>" }
            s += staffTag
            if p.tiePrev || p.tieNext {
                s += "<notations>" + (p.tiePrev ? "<tied type=\"stop\"/>" : "") + (p.tieNext ? "<tied type=\"start\"/>" : "") + "</notations>"
            }
            out += s + "</note>\n"
        }
        return out
    }
}

// MARK: - PDF

enum ScorePDF {
    /// US-Letter pages, black on white, systems never split across pages.
    static func data(score: NScore, title: String, subtitle: String, firstMeasure: Int) -> Data {
        let pageW: CGFloat = 612, pageH: CGFloat = 792, margin: CGFloat = 48
        let lay = ScoreLayout(score: score, width: pageW - margin * 2, space: 6.4, title: title, subtitle: subtitle, firstMeasureNumber: firstMeasure)
        var style = ScoreStyle()
        style.ink = .black; style.staffLine = NSColor(white: 0.2, alpha: 1); style.dim = NSColor(white: 0.4, alpha: 1)
        style.selected = []

        // paginate: systems keep their layout positions; each page just shifts them up to the top margin
        let avail = pageH - margin * 2 - 14
        var pages: [[Int]] = []
        var i = 0
        while i < lay.systems.count {
            let base = i == 0 ? 0 : lay.systems[i].y
            var page = [i]
            while let j = Optional(page.last! + 1), j < lay.systems.count, lay.systems[j].y + lay.systems[j].height - base <= avail { page.append(j) }
            pages.append(page); i = page.last! + 1
        }

        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for (pi, page) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(box)
            ctx.saveGState()
            ctx.translateBy(x: margin, y: pageH); ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let base = page[0] == 0 ? 0 : lay.systems[page[0]].y
            let dy = margin - base
            for i in page { lay.draw(system: i, ctx: ctx, style: style, dy: dy) }
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.4, alpha: 1)]
            ("\(pi + 1)" as NSString).draw(at: CGPoint(x: (pageW - margin * 2) / 2, y: pageH - margin - 4), withAttributes: a)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }
}

// MARK: - Session actions

extension Session {
    private func scoreFileName(_ track: Track, _ clip: Clip) -> String { "\(track.name) – \(clip.name)" }

    func exportScorePDF() {
        guard let cur = currentScore() else { toast = "Select a pattern first"; return }
        let bpb = project.beatsPerBar
        deliverExport(fileName: scoreFileName(cur.track, cur.clip) + ".pdf", type: .pdf, failure: "Couldn't save the PDF") { url in
            let d = ScorePDF.data(score: cur.score, title: cur.clip.name, subtitle: "\(self.project.name) · \(cur.track.name)", firstMeasure: Int(cur.clip.start / bpb) + 1)
            try d.write(to: url)
        }
    }

    func exportScoreMusicXML() {
        guard let cur = currentScore() else { toast = "Select a pattern first"; return }
        let bpb = project.beatsPerBar
        deliverExport(fileName: scoreFileName(cur.track, cur.clip) + ".musicxml", type: UTType(filenameExtension: "musicxml") ?? .xml, failure: "Couldn't save the file") { url in
            let xml = MusicXML.build(score: cur.score, title: cur.clip.name, partName: cur.track.name, tempo: self.project.tempo, firstMeasure: Int(cur.clip.start / bpb) + 1)
            try xml.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
