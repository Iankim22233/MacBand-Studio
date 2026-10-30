import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// A tiny picture of a project: all its notes in one roll, in the track colours.
struct ProjectPreview: View {
    let info: ProjectInfo
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(colors: [Color(white: 0.09), Color(white: 0.05)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            guard !info.preview.isEmpty else {
                let t = Text(info.audioTracks > 0 ? "audio" : "empty").font(.system(size: 11)).foregroundColor(.white.opacity(0.3))
                ctx.draw(t, at: CGPoint(x: size.width / 2, y: size.height / 2)); return
            }
            let lo = Int(info.preview.map { $0.pitch }.min() ?? 48) - 1, hi = max(lo + 12, Int(info.preview.map { $0.pitch }.max() ?? 84) + 1)
            let span = CGFloat(hi - lo + 1), pad: CGFloat = 6
            let w = size.width - pad * 2, h = size.height - pad * 2
            let end = CGFloat(max(info.endBeat, 4))
            for n in info.preview {
                let x = pad + CGFloat(n.start) / end * w
                let nw = max(1.5, CGFloat(n.end - n.start) / end * w)
                let y = pad + h - CGFloat(Int(n.pitch) - lo + 1) / span * h
                let ci = n.track < info.colors.count ? info.colors[n.track] : n.track
                ctx.fill(Path(CGRect(x: x, y: y, width: nw, height: max(1.5, h / span))), with: .color(Palette.color(ci).opacity(0.85)))
            }
        }
    }
}

#if os(macOS)
struct ProjectBrowserView: View {
    @EnvironmentObject var session: Session
    @StateObject private var library = ProjectLibrary()
    @State private var query = ""
    @State private var selected: String?

    private func filtered(_ list: [ProjectInfo]) -> [ProjectInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? list : list.filter { $0.name.lowercased().contains(q) }
    }
    private var allShown: [ProjectInfo] { filtered(library.inFolder) + filtered(library.recent) + filtered(library.other) }
    private var chosen: ProjectInfo? { selected.flatMap { id in allShown.first { $0.id == id } } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section("In your MacBand folder", filtered(library.inFolder), emptyText: library.scanning ? "Looking…" : "Nothing saved here yet. Press ⌘S in a project and it goes in this folder.")
                    if !filtered(library.recent).isEmpty { section("Opened recently", filtered(library.recent), emptyText: "") }
                    if !filtered(library.other).isEmpty { section("Found elsewhere on this Mac", filtered(library.other), emptyText: "") }
                    if library.scanning { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Searching for more projects…").font(.system(size: 11)).foregroundStyle(Theme.faint) } }
                }
                .padding(18)
            }
            .background(Theme.well)
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 900, height: 620)
        .background(Theme.window)
        .buttonStyle(VistaButtonStyle())
        .onAppear { library.refresh(); selected = library.inFolder.first?.id }
        .onChange(of: library.inFolder) { list in if selected == nil { selected = list.first?.id } }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Projects").font(.system(size: 16, weight: .bold))
                Text(abbreviated(library.folder)).font(.system(size: 11)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.faint)
                TextField("Search projects", text: $query).textFieldStyle(.plain).frame(width: 170)
            }
            .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 26)
            .background(Rectangle().fill(Theme.well)).overlay(Rectangle().stroke(Theme.line))
            Button("Show Folder") { NSWorkspace.shared.open(ProjectsFolder.ensure().url) }.help("Open the MacBand folder in the Finder")
            Button("Change Folder…") { chooseFolder() }
        }
        .padding(.horizontal, 16).frame(height: 56).background(Theme.panel)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("Show this window when MacBand starts", isOn: Binding(get: { session.showBrowserAtLaunch }, set: { session.showBrowserAtLaunch = $0 }))
                .toggleStyle(VistaCheckboxStyle()).font(.system(size: 11)).foregroundStyle(Theme.dim)
            Spacer()
            Button("Other File…") { session.showProjectBrowser = false; session.openProjectFromPanel() }.help("Pick a project file from anywhere")
            Button("New Project") { session.showProjectBrowser = false; session.newProject() }
            Button("Cancel") { session.showProjectBrowser = false }.keyboardShortcut(.cancelAction)
            Button { if let c = chosen { open(c) } } label: { Text("Open").padding(.horizontal, 10) }
                .buttonStyle(VistaButtonStyle(compact: false)).disabled(chosen == nil).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).frame(height: 54).background(Theme.panel)
    }

    private func section(_ title: String, _ list: [ProjectInfo], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title)
            if list.isEmpty {
                if !emptyText.isEmpty { Text(emptyText).font(.system(size: 12)).foregroundStyle(Theme.dim).padding(.vertical, 6) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 196, maximum: 230), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(list) { info in
                        ProjectCard(info: info, selected: selected == info.id)
                            .onTapGesture(count: 2) { selected = info.id; open(info) }
                            .onTapGesture { selected = info.id }
                            .contextMenu {
                                Button("Open") { open(info) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([info.url]) }
                                if RecentProjects.urls.contains(info.url) { Button("Remove from Recents") { RecentProjects.remove(info.url); library.refresh() } }
                            }
                    }
                }
            }
        }
    }

    private func open(_ info: ProjectInfo) {
        session.showProjectBrowser = false
        session.openProjectConfirmed(info.url)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = ProjectsFolder.url.deletingLastPathComponent()
        panel.message = "Choose the folder MacBand keeps your projects in"
        if panel.runModal() == .OK, let u = panel.url { ProjectsFolder.choose(u); library.refresh() }
    }

    private func abbreviated(_ u: URL) -> String { u.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}
#endif

struct ProjectCard: View {
    let info: ProjectInfo
    let selected: Bool
    @State private var hover = false

    private var dateText: String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: info.modified, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectPreview(info: info).frame(height: 96)
            VStack(alignment: .leading, spacing: 3) {
                Text(info.name).font(Theme.vista(12)).foregroundStyle(.white).lineLimit(1)
                Text(info.details).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(dateText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VistaFace(state: selected, border: 0.75))
        }
        .overlay(Rectangle().strokeBorder(Color.white.opacity(selected ? 0.95 : (hover ? 0.5 : 0.18)), lineWidth: selected ? 2 : 1))
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .help(info.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
    }
}
