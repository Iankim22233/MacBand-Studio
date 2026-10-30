import SwiftUI
import UniformTypeIdentifiers

/// Instrument picker items: built-in General MIDI sounds, drum kit, and installed plugins.
struct InstrumentMenuItems: View {
    @EnvironmentObject var session: Session
    var allowDrums = true
    let pick: (InstrumentSpec) -> Void

    var body: some View {
        Menu("Built-in Sounds") {
            ForEach(GM.families, id: \.0) { fam in
                Menu(fam.0) {
                    ForEach(Array(fam.1), id: \.self) { i in
                        Button(GM.programs[i]) { pick(InstrumentSpec(gmProgram: i)) }
                    }
                }
            }
        }
        if allowDrums { Button("Drum Kit") { pick(InstrumentSpec(isDrums: true)) } }
        Divider()
        PluginInstrumentItems(pick: pick)
        Divider()
        Button("Plugin Manager…") { session.showPluginManager = true }
    }
}

private struct PluginInstrumentItems: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var lib: PluginLibrary
    let pick: (InstrumentSpec) -> Void
    init(pick: @escaping (InstrumentSpec) -> Void) {
        self.pick = pick
        _lib = ObservedObject(wrappedValue: PluginLibrary.shared)
    }
    var body: some View {
        let inst = lib.instruments
        if inst.isEmpty {
            Text(lib.scanning ? "Scanning plugins…" : "No plugin instruments found").foregroundStyle(.secondary)
        } else {
            Menu("Audio Unit Instruments") {
                ForEach(inst.filter { $0.spec.format == .au }) { lp in
                    Button("\(lp.spec.name)  —  \(lp.spec.vendor)") { choose(lp) }
                }
            }
            if inst.contains(where: { $0.spec.format == .vst3 }) {
                Menu("VST3 Instruments") {
                    ForEach(inst.filter { $0.spec.format == .vst3 }) { lp in
                        Button("\(lp.spec.name)  —  \(lp.spec.vendor)") { choose(lp) }
                    }
                }
            }
        }
    }
    private func choose(_ lp: LibraryPlugin) {
        var s = lp.spec; s.id = UUID()
        pick(InstrumentSpec(plugin: s))
    }
}

struct EffectMenuItems: View {
    @ObservedObject private var lib = PluginLibrary.shared
    let pick: (PluginSpec) -> Void
    var body: some View {
        let fx = lib.effects
        if fx.isEmpty {
            Text(lib.scanning ? "Scanning plugins…" : "No effect plugins found").foregroundStyle(.secondary)
        } else {
            Menu("Audio Unit Effects") {
                ForEach(fx.filter { $0.spec.format == .au }) { lp in Button("\(lp.spec.name)  —  \(lp.spec.vendor)") { pick(lp.spec) } }
            }
            if fx.contains(where: { $0.spec.format == .vst3 }) {
                Menu("VST3 Effects") {
                    ForEach(fx.filter { $0.spec.format == .vst3 }) { lp in Button("\(lp.spec.name)  —  \(lp.spec.vendor)") { pick(lp.spec) } }
                }
            }
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject var session: Session

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if session.masterSelected {
                    MasterInspector()
                } else if let t = session.selectedTrack {
                    TrackInspector(track: t)
                        .environment(\.vistaTint, Palette.nsColor(t.colorIndex))      // the buttons on an instrument take its colour
                    if let loc = session.selectedClipLocation {
                        ClipInspector(track: session.project.tracks[loc.track], clip: session.project.tracks[loc.track].clips[loc.clip])
                            .environment(\.vistaTint, Palette.nsColor(t.colorIndex))
                    }
                } else {
                    Text("No track selected").foregroundStyle(Theme.dim).font(.system(size: 12))
                }
                ProjectInspector()
            }
            .padding(14)
        }
        .background(Theme.panel)
    }
}

/// The Master track: effects on the whole mix, plus the master volume and bass.
struct MasterInspector: View {
    @EnvironmentObject var session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Master")
            Text("Everything you hear passes through here, so an effect added here (a reverb, a compressor, an EQ) works on the whole song instead of one instrument.")
                .font(.system(size: 11)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)

            SectionLabel(text: "Effects")
            VStack(spacing: 4) {
                ForEach(session.project.masterInserts) { fx in
                    HStack(spacing: 6) {
                        IconButton(symbol: "power", active: !fx.bypassed, help: fx.bypassed ? "Enable" : "Bypass", size: 20, fontSize: 9) { session.toggleMasterBypass(specID: fx.id) }
                        Text(fx.name).font(.system(size: 12)).lineLimit(1).foregroundStyle(fx.bypassed ? Theme.faint : Theme.text)
                        Spacer()
                        IconButton(symbol: "slider.horizontal.3", help: "Open plugin window", size: 20, fontSize: 9) { session.openMasterEditor(spec: fx) }
                        IconButton(symbol: "xmark", help: "Remove", size: 20, fontSize: 9) { session.removeMasterInsert(specID: fx.id) }
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(Rectangle().fill(Theme.raised))
                }
                Menu {
                    EffectMenuItems { spec in session.addMasterInsert(spec) }
                    Divider()
                    Button("Plugin Manager…") { session.showPluginManager = true }
                } label: {
                    HStack { Image(systemName: "plus"); Text("Add Effect to Master") }
                        .font(Theme.vista(11)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .vistaBackground()
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                if session.project.masterInserts.isEmpty {
                    Text("No effects yet. They run in the order shown, then the limiter that protects your speakers.").font(.system(size: 10)).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SectionLabel(text: "Mix")
            LabeledSlider(label: "Volume", value: Binding(get: { session.project.masterVolume }, set: { v in session.modify { $0.masterVolume = v } }), range: 0...1,
                          display: String(format: "%.0f%%", session.project.masterVolume / 0.8 * 100), onBegin: { session.pushUndo() })
            LabeledSlider(label: "Bass", value: Binding(get: { session.project.masterBass }, set: { v in session.modify { $0.masterBass = (v * 2).rounded() / 2 } }), range: -12...6,
                          display: String(format: "%+.1f dB", session.project.masterBass), onBegin: { session.pushUndo() })
                .help("Less or more bass on the whole mix: a low shelf below about 140 Hz")
        }
    }
}

struct TrackInspector: View {
    @EnvironmentObject var session: Session
    let track: Track

    private func update(_ body: @escaping (inout Track) -> Void) {
        session.edit { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { body(&p.tracks[i]) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Track")
            TextField("Name", text: Binding(get: { track.name }, set: { v in update { $0.name = v } }))
                .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 28)
                .background(Rectangle().fill(Theme.well))

            HStack(spacing: 6) {
                ForEach(0..<Palette.trackColors.count, id: \.self) { i in
                    VistaSwatch(color: Palette.nsColor(i), selected: track.colorIndex % Palette.trackColors.count == i) { update { $0.colorIndex = i } }
                }
            }

            if track.kind == .instrument {
            SectionLabel(text: "Instrument")
            Button { session.soundTarget = .track(track.id) } label: {
                HStack {
                    Image(systemName: track.instrument.plugin != nil ? "puzzlepiece.extension" : (track.instrument.isDrums ? "circle.grid.3x3.fill" : "pianokeys"))
                    Text(track.instrument.displayName).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 30)
                .frame(maxWidth: .infinity)
            }.buttonStyle(VistaButtonStyle(compact: false)).help("Open the Sound Library (⌘B)")

            if let p = track.instrument.plugin {
                HStack {
                    Button("Open \(p.name)") { session.openEditor(trackID: track.id, spec: p) }
                    Text(p.format == .au ? "AU" : "VST3").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                }.font(.system(size: 11)).buttonStyle(VistaButtonStyle())
            }

            } else {
                SectionLabel(text: "Audio")
                Text("Import or drop a vocal onto this track, then open the Vocal Tune tab to tune it.").font(.system(size: 11)).foregroundStyle(Theme.dim)
            }

            SectionLabel(text: "Effects")
            VStack(spacing: 4) {
                ForEach(track.inserts) { fx in
                    HStack(spacing: 6) {
                        IconButton(symbol: "power", active: !fx.bypassed, help: fx.bypassed ? "Enable" : "Bypass", size: 20, fontSize: 9) { session.toggleBypass(trackID: track.id, specID: fx.id) }
                        Text(fx.name).font(.system(size: 12)).lineLimit(1).foregroundStyle(fx.bypassed ? Theme.faint : Theme.text)
                        Spacer()
                        IconButton(symbol: "slider.horizontal.3", help: "Open plugin window", size: 20, fontSize: 9) { session.openEditor(trackID: track.id, spec: fx) }
                        IconButton(symbol: "xmark", help: "Remove", size: 20, fontSize: 9) { session.removeInsert(trackID: track.id, specID: fx.id) }
                    }
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(Rectangle().fill(Theme.raised))
                }
                Menu {
                    EffectMenuItems { spec in session.addInsert(trackID: track.id, spec) }
                    Divider()
                    Button("Plugin Manager…") { session.showPluginManager = true }
                } label: {
                    HStack { Image(systemName: "plus"); Text("Add Effect") }
                        .font(Theme.vista(11)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .vistaBackground()
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }

            SectionLabel(text: "Mix")
            LabeledSlider(label: "Volume", value: Binding(get: { track.volume }, set: { v in session.modify { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].volume = v } } }), range: 0...1, display: String(format: "%.0f%%", track.volume / 0.8 * 100),
                          onBegin: { session.pushUndo() })
            LabeledSlider(label: "Pan", value: Binding(get: { track.pan }, set: { v in session.modify { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].pan = v } } }), range: -1...1,
                          display: abs(track.pan) < 0.02 ? "C" : (track.pan < 0 ? "L\(Int(-track.pan * 100))" : "R\(Int(track.pan * 100))"),
                          onBegin: { session.pushUndo() })
            if track.kind == .instrument {
            LabeledSlider(label: "Trim", value: Binding(get: { track.trim }, set: { v in session.modify { p in if let i = p.tracks.firstIndex(where: { $0.id == track.id }) { p.tracks[i].trim = (v * 2).rounded() / 2 } } } ), range: -24...24,
                          display: String(format: "%+.1f dB", track.trim), onBegin: { session.pushUndo() })
                .help("Extra gain on top of the fader, in dB. Auto Balance sets it so tracks are equally loud; the fader alone can't lift a very quiet sound.")
            VistaStepper(value: Binding(get: { Double(track.bendRange) }, set: { v in update { $0.bendRange = Int(v) } }), range: 1...48) {
                HStack {
                    Text("Slide range").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    Spacer()
                    Text("\(track.bendRange) st").font(.system(size: 12)).monospacedDigit()
                }
            }.help("Pitch-bend range in semitones used by slide notes. Match this to your plugin's bend range.")
            }
        }
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: String
    var onBegin: () -> Void = {}
    @State private var began = false
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.dim).frame(width: 52, alignment: .leading)
            VistaSlider(value: $value, in: range, onEditingChanged: { editing in
                if editing && !began { onBegin(); began = true }
                if !editing { began = false }
            }).controlSize(.small).tint(Theme.accent)
            Text(display).font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.dim).lineLimit(1).fixedSize().frame(width: 58, alignment: .trailing)
        }
    }
}

struct ClipInspector: View {
    @EnvironmentObject var session: Session
    let track: Track
    let clip: Clip
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Pattern")
            TextField("Name", text: Binding(get: { clip.name }, set: { v in
                session.edit { p in
                    if let t = p.tracks.firstIndex(where: { $0.id == track.id }), let c = p.tracks[t].clips.firstIndex(where: { $0.id == clip.id }) { p.tracks[t].clips[c].name = v }
                }
            })).textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(height: 26).background(Rectangle().fill(Theme.well))
            HStack {
                Text("\(clip.notes.count) notes").font(.system(size: 11)).foregroundStyle(Theme.dim)
                let slides = clip.notes.filter { $0.isSlide }.count
                if slides > 0 { Text("· \(slides) slide").font(.system(size: 11)).foregroundStyle(Theme.dim) }
                Spacer()
                Button("Duplicate") { session.duplicateClip(trackID: track.id, clipID: clip.id) }
                Button("Delete", role: .destructive) { session.deleteClip(trackID: track.id, clipID: clip.id) }
            }.buttonStyle(VistaButtonStyle())
        }
    }
}

struct ProjectInspector: View {
    @EnvironmentObject var session: Session
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Project")
            TextField("Name", text: Binding(get: { session.project.name }, set: { v in session.modify { $0.name = v }; session.isDirty = true }))
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(height: 26).background(Rectangle().fill(Theme.well))
            Text("\(session.project.tracks.count) tracks · \(session.project.tracks.reduce(0) { $0 + $1.clips.reduce(0) { $0 + $1.notes.count } }) notes")
                .font(.system(size: 11)).foregroundStyle(Theme.faint)
        }
    }
}
