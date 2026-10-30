import SwiftUI

/// The transport for a touch screen: the same buttons as the Mac, smaller, in one row when there is room and two rows when there isn't.
struct IOSTransportBar: View {
    @EnvironmentObject var session: Session
    @Environment(\.compactLayout) private var compact

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { projectMenu; Spacer(minLength: 4); controls; lcd; tempo; Spacer(minLength: 4); trailing }
                .padding(.horizontal, 10).frame(height: 46)
            VStack(spacing: 4) {
                HStack(spacing: 8) { projectMenu; Spacer(minLength: 4); lcd; tempo; trailing }
                HStack(spacing: 6) { controls }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .background(Theme.panel)
    }

    private var projectMenu: some View {
        Menu {
            Button { session.newProject() } label: { Label("New Project", systemImage: "doc.badge.plus") }
            Button { session.openProject() } label: { Label("Projects…", systemImage: "folder") }
            Button { session.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
            Button { session.saveAs() } label: { Label("Save As…", systemImage: "doc.on.doc") }
            Toggle("Auto Save", isOn: Binding(get: { session.autoSaveEnabled }, set: { session.autoSaveEnabled = $0 }))
            Text(session.lastAutoSaveText)
            Divider()
            Menu("Import") {
                Button("MIDI File…") { session.importMIDI() }
                Button("Audio…") { session.importAudio() }
                Button("Project or GarageBand Project…") { session.importBandProject() }
            }
            Menu("Export") {
                Button("MIDI File…") { session.exportMIDI() }
                Button("Audio (WAV)…") { session.exportAudio() }
                Button("Sheet Music (PDF)…") { session.exportScorePDF() }
                Button("Sheet Music (MusicXML)…") { session.exportScoreMusicXML() }
            }
            Divider()
            Menu("Button Color") { ButtonColorMenu() }
            Button { session.startIntro() } label: { Label("Show Introduction…", systemImage: "sparkles") }
            Text("Sounds: GeneralUser GS by S. Christian Collins")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal").font(.system(size: 11, weight: .bold))
                Text(session.project.name + (session.isDirty ? " •" : "")).font(Theme.vista(12)).lineLimit(1)
            }
            .foregroundStyle(.white).frame(maxWidth: 190, alignment: .leading)
            .padding(.horizontal, 10).frame(height: 32).vistaBackground()
        }
        .buttonStyle(.plain)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "backward.end.fill", size: 36) { session.rewind() }
            PlayButton.Inner(transport: session.transport)
            RecordButton.Inner(transport: session.transport)
            LoopButton()
            IconButton(symbol: "metronome", active: session.metronome, size: 36) { session.metronome.toggle() }
        }
    }

    private var lcd: some View { CompactLCD(transport: session.transport) }

    private var tempo: some View {
        HStack(spacing: 4) {
            Button {
                session.prompt = Prompt(title: "Tempo", message: "Beats per minute (20 to 300)",
                                        choices: [.init(title: "Set"), .init(title: "Cancel", role: .cancel)],
                                        textFieldPlaceholder: "BPM", textFieldInitial: String(format: "%g", session.project.tempo)) { text in
                    if let v = Double(text) { session.setTempo(v) }
                }
            } label: {
                VStack(spacing: 0) {
                    Text(session.project.tempoPoints.isEmpty ? String(format: "%g", session.project.tempo) : String(format: "%.1f", session.project.bpm(at: session.transport.beat)))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                    Text(session.project.tempoPoints.isEmpty ? "BPM" : "AUTO").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.faint)
                }
                .foregroundStyle(Theme.text).frame(width: 56, height: 36)
                .background(Rectangle().fill(Theme.well)).overlay(Rectangle().stroke(Theme.line))
            }.buttonStyle(.plain)
            TimeSigControl()
        }
    }

    private var trailing: some View {
        HStack(spacing: 4) {
            if !session.lastMIDIDevice.isEmpty { Image(systemName: "pianokeys").font(.system(size: 12)).foregroundStyle(Theme.dim) }
            IconButton(symbol: "pianokeys", active: session.showKeyboard, size: 36) { session.showKeyboard.toggle() }
            IconButton(symbol: "slider.horizontal.3", size: 36) { session.showInspector.toggle() }
        }
    }
}

/// Bars, beats and the time, small enough for a phone.
struct CompactLCD: View {
    @EnvironmentObject var session: Session
    @ObservedObject var transport: Transport
    var body: some View {
        let p = session.project, b = transport.beat, bpb = p.beatsPerBar
        let bar = Int(b / bpb) + 1, beat = Int(b.truncatingRemainder(dividingBy: bpb)) + 1
        let secs = p.seconds(atBeat: b)
        VStack(spacing: 0) {
            Text(String(format: "%03d.%d", bar, beat)).font(.system(size: 16, weight: .medium, design: .monospaced))
            Text(String(format: "%02d:%04.1f", Int(secs) / 60, secs.truncatingRemainder(dividingBy: 60))).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.dim)
        }
        .foregroundStyle(Theme.text).frame(width: 66, height: 36)
        .background(Rectangle().fill(Theme.well)).overlay(Rectangle().stroke(Theme.line))
    }
}
