import SwiftUI
import UniformTypeIdentifiers

/// Where a sound picked in the browser goes.
enum SoundTarget: Equatable {
    case track(UUID)
    case newTrack
}

struct SoundBrowserView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var library = SoundLibrary.shared
    @ObservedObject private var plugins = PluginLibrary.shared
    let target: SoundTarget

    @State private var search = ""
    @State private var selectedGroup: String?
    @State private var selectedCategory: String?
    @State private var selectedID: String?
    @State private var showUnavailable = false
    @State private var auditionError: String?
    @State private var auditioning = false

    private var allEntries: [SoundEntry] {
        var list = library.entries
        for lp in plugins.instruments {
            var s = lp.spec; s.id = UUID()
            list.append(SoundEntry(id: "plug:\(lp.spec.key)", name: lp.spec.name, group: SoundGroup.plugins,
                                   category: lp.spec.format == .au ? "Audio Units" : "VST3", isDrums: false, spec: InstrumentSpec(plugin: s)))
        }
        return list
    }

    private var visible: [SoundEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return allEntries.filter { e in
            if !showUnavailable && !library.isAvailable(e) { return false }
            if let g = selectedGroup, e.group != g { return false }
            if let c = selectedCategory, e.category != c { return false }
            if q.isEmpty { return true }
            return e.name.lowercased().contains(q) || e.category.lowercased().contains(q) || e.group.lowercased().contains(q)
        }
    }

    private var targetName: String {
        if case .track(let id) = target, let t = session.project.tracks.first(where: { $0.id == id }) { return "for “\(t.name)”" }
        return "for a new track"
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                sidebar.frame(width: 232)
                Divider().overlay(Theme.line)
                list
            }
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 880, height: 580)
        .background(Theme.window)
        .buttonStyle(VistaButtonStyle())
        .onAppear { if library.entries.isEmpty { library.rescan() } }
        .onDisappear { session.engine.stopPreviewNotes() }
        #else
        phoneBody
        #endif
    }

    #if os(iOS)
    /// On a phone: one column. The categories are a menu above the list instead of a sidebar.
    private var phoneBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Sound Library").font(.system(size: 15, weight: .bold))
                Text(targetName).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                Spacer()
                Button { addSoundFont() } label: { Image(systemName: "plus").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30) }
                Button("Done") { session.soundTarget = nil }
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.panel)
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                    TextField("Search sounds", text: $search).textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.faint) }
                }
                .font(.system(size: 14)).padding(.horizontal, 8).frame(height: 34)
                .background(Rectangle().fill(Theme.well)).overlay(Rectangle().stroke(Theme.line))
                categoryMenu
            }
            .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.panel)
            Divider().overlay(Theme.line)
            list
            Divider().overlay(Theme.line)
            HStack(spacing: 8) {
                Button { if let e = selectedEntry { audition(e) } } label: { Label("Audition", systemImage: "play.fill") }.disabled(selectedEntry == nil)
                Button { session.engine.stopPreviewNotes() } label: { Label("Stop", systemImage: "stop.fill") }
                if let err = auditionError { Text(err).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button { if let e = selectedEntry { use(e) } } label: { Text("Use Sound").padding(.horizontal, 8) }
                    .buttonStyle(VistaButtonStyle(compact: false)).disabled(selectedEntry == nil)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.panel)
        }
        .background(Theme.window)
        .buttonStyle(VistaButtonStyle())
        .onAppear { if library.entries.isEmpty { library.rescan() } }
        .onDisappear { session.engine.stopPreviewNotes() }
    }

    private var categoryLabel: String {
        if let c = selectedCategory { return c }
        if let g = selectedGroup { return "All \(g)" }
        return "All Sounds"
    }

    private var categoryMenu: some View {
        Menu {
            Button("All Sounds") { selectedGroup = nil; selectedCategory = nil }
            ForEach(groups, id: \.group) { g in
                Menu(g.group) {
                    Button("All \(g.group)") { selectedGroup = g.group; selectedCategory = nil }
                    ForEach(g.categories, id: \.name) { c in Button("\(c.name)  (\(c.count))") { selectedGroup = g.group; selectedCategory = c.name } }
                }
            }
        } label: {
            HStack(spacing: 4) { Text(categoryLabel).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)) }
                .font(Theme.vista(12)).foregroundStyle(.white).padding(.horizontal, 10).frame(height: 34).frame(maxWidth: 190).vistaBackground()
        }.buttonStyle(.plain)
    }
    #endif

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            Text("Sound Library").font(.system(size: 14, weight: .bold))
            Text(targetName).font(.system(size: 12)).foregroundStyle(Theme.dim)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Search sounds", text: $search).textFieldStyle(.plain).frame(width: 190)
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.faint) }
            }
            .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 26)
            .background(Rectangle().fill(Theme.well)).overlay(Rectangle().stroke(Theme.line))
            Button("Add SoundFont…") { addSoundFont() }
            Button { session.soundTarget = nil } label: { Image(systemName: "xmark") }.help("Close")
        }
        .padding(.horizontal, 14).frame(height: 48).background(Theme.panel)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sidebarRow("All Sounds", count: allEntries.filter { showUnavailable || library.isAvailable($0) }.count,
                           active: selectedGroup == nil) { selectedGroup = nil; selectedCategory = nil }
                ForEach(groups, id: \.group) { g in
                    SectionLabel(text: g.group).padding(.top, 12).padding(.bottom, 3).padding(.horizontal, 10)
                    sidebarRow("All \(g.group)", count: g.categories.reduce(0) { $0 + $1.count },
                               active: selectedGroup == g.group && selectedCategory == nil) { selectedGroup = g.group; selectedCategory = nil }
                    ForEach(g.categories, id: \.name) { c in
                        sidebarRow(c.name, count: c.count, indent: true, active: selectedGroup == g.group && selectedCategory == c.name) {
                            selectedGroup = g.group; selectedCategory = c.name
                        }
                    }
                }
                if library.scanning { HStack { ProgressView().controlSize(.small); Text("Scanning…").font(.system(size: 11)).foregroundStyle(Theme.dim) }.padding(10) }
            }
            .padding(.vertical, 8).padding(.horizontal, 6)
        }
        .background(Theme.panel)
    }

    private var groups: [(group: String, categories: [(name: String, count: Int)])] {
        var g = library.categories(includeUnavailable: showUnavailable)
        let plug = plugins.instruments
        if !plug.isEmpty {
            let au = plug.filter { $0.spec.format == .au }.count, v3 = plug.count - au
            var cats: [(name: String, count: Int)] = []
            if au > 0 { cats.append((name: "Audio Units", count: au)) }
            if v3 > 0 { cats.append((name: "VST3", count: v3)) }
            g.append((group: SoundGroup.plugins, categories: cats))
        }
        return g
    }

    private func sidebarRow(_ title: String, count: Int, indent: Bool = false, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text("\(count)").foregroundStyle(Color.white.opacity(active ? 0.9 : 0.55))
            }
            .font(Theme.vista(12))
            .foregroundStyle(Color.white.opacity(active ? 1 : 0.85))
            .padding(.leading, indent ? 20 : 10).padding(.trailing, 10).frame(height: 24)
            .background(VistaFace(state: active, border: 0.75))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var list: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { e in
                            row(e).id(e.id)
                        }
                        if visible.isEmpty {
                            Text(library.scanning ? "Scanning for sounds…" : "No sounds match.")
                                .font(.system(size: 12)).foregroundStyle(Theme.dim).padding(30)
                        }
                    }
                }
                .onChange(of: selectedCategory) { _ in if let f = visible.first { proxy.scrollTo(f.id, anchor: .top) } }
            }
        }
        .background(Theme.well)
    }

    private var rowHeight: CGFloat {
        #if os(iOS)
        return 40
        #else
        return 28
        #endif
    }

    private func row(_ e: SoundEntry) -> some View {
        let sel = selectedID == e.id
        let ok = library.isAvailable(e)
        return HStack(spacing: 10) {
            Image(systemName: e.isDrums ? "circle.grid.3x3.fill" : (e.spec.plugin != nil ? "puzzlepiece.extension" : "pianokeys"))
                .font(.system(size: 11)).foregroundStyle(Color.white.opacity(sel ? 1 : 0.6)).frame(width: 18)
            Text(e.name).font(Theme.vista(12)).lineLimit(1)
            if !ok { Text("samples missing").font(.system(size: 10)).foregroundStyle(.orange) }
            Spacer()
            Text(selectedCategory == nil ? "\(e.group) · \(e.category)" : "").font(.system(size: 11)).foregroundStyle(Color.white.opacity(sel ? 0.85 : 0.55)).lineLimit(1)
            if e.isDrums { Text("DRUMS").font(Theme.vista(9)).foregroundStyle(.white).padding(.horizontal, 5).frame(height: 15).background(VistaFace(state: sel ? true : false, border: 1)) }
        }
        .foregroundStyle(Color.white.opacity(sel ? 1 : (ok ? 0.85 : 0.5)))
        .padding(.horizontal, 12).frame(height: rowHeight)
        .background(VistaFace(state: sel, border: 0.75))
        .padding(.vertical, 0.5)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selectedID = e.id; use(e) }
        .onTapGesture { selectedID = e.id; audition(e) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { if let e = selectedEntry { audition(e) } } label: { Label("Audition", systemImage: "play.fill") }.disabled(selectedEntry == nil)
            Button { session.engine.stopPreviewNotes(); auditioning = false } label: { Label("Stop", systemImage: "stop.fill") }
            if let err = auditionError { Text(err).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1) }
            else if library.validating { Text("Checking which instruments can load… (one-time)").font(.system(size: 11)).foregroundStyle(Theme.faint) }
            else { Text("Click a sound to hear it · double-click to use it").font(.system(size: 11)).foregroundStyle(Theme.faint) }
            Spacer()
            Toggle("Show unavailable", isOn: $showUnavailable).toggleStyle(VistaCheckboxStyle()).font(.system(size: 11)).foregroundStyle(Theme.dim)
            Button("Cancel") { session.soundTarget = nil }.keyboardShortcut(.cancelAction)
            Button { if let e = selectedEntry { use(e) } } label: { Text("Use Sound").padding(.horizontal, 6) }
                .buttonStyle(VistaButtonStyle(compact: false)).disabled(selectedEntry == nil).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).frame(height: 48).background(Theme.panel)
    }

    // MARK: Actions

    private var selectedEntry: SoundEntry? { selectedID.flatMap { id in allEntries.first { $0.id == id } } }

    private func audition(_ e: SoundEntry) {
        auditionError = nil
        session.engine.preview(e.spec) { err in
            if let err { auditionError = "Couldn't load “\(e.name)”: \(err)" }
        }
    }

    private func use(_ e: SoundEntry) {
        var spec = e.spec
        if spec.plugin != nil { spec.plugin!.id = UUID() }
        session.applySound(spec, to: target)
        session.soundTarget = nil
    }

    private func addSoundFont() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sf2") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose SoundFont (.sf2) files to add to the library"
        if panel.runModal() == .OK { for u in panel.urls { library.addSoundFont(u) } }
        #else
        // The picker gives temporary copies: keep them in the app's Sounds folder, which the library scans.
        session.pickFiles([UTType(filenameExtension: "sf2") ?? .data, UTType(filenameExtension: "dls") ?? .data], multiple: true) { urls in
            let folder = ProjectsFolder.soundsFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for u in urls {
                let dest = folder.appendingPathComponent(u.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: u, to: dest)
            }
            library.rescan()
            session.showToast("Added \(urls.count) sound file\(urls.count == 1 ? "" : "s") to the library")
        }
        #endif
    }
}

extension Session {
    func applySound(_ spec: InstrumentSpec, to target: SoundTarget) {
        switch target {
        case .track(let id): setInstrument(trackID: id, spec)
        case .newTrack: addTrack(instrument: spec)
        }
    }
}
