import SwiftUI

/// The projects in the app's folder (shown in the Files app as "MacBand Studio"), as a grid of previews.
struct IOSProjectBrowser: View {
    @EnvironmentObject var session: Session
    @StateObject private var library = ProjectLibrary()
    @State private var selected: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if library.inFolder.isEmpty && library.recent.isEmpty {
                        Text("Nothing saved yet. Save a project and it appears here, and in the Files app under MacBand Studio.")
                            .font(.system(size: 13)).foregroundStyle(Theme.dim).padding(.top, 20)
                    }
                    grid("Your projects", library.inFolder)
                    grid("Recently opened elsewhere", library.recent)
                }.padding(16)
            }
            .background(Theme.window)
            .navigationTitle("Projects").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { session.showProjectBrowser = false } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { session.showProjectBrowser = false; session.newProject() } label: { Label("New", systemImage: "plus") }
                    Button { session.showProjectBrowser = false; session.openProjectFromPanel() } label: { Label("From Files…", systemImage: "folder") }
                }
            }
            .onAppear { library.refresh(includeOther: false) }
        }
    }

    @ViewBuilder private func grid(_ title: String, _ list: [ProjectInfo]) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: title)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 230), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(list) { info in
                        ProjectCard(info: info, selected: selected == info.id)
                            .onTapGesture { session.showProjectBrowser = false; session.openProjectConfirmed(info.url) }
                            .contextMenu {
                                Button("Open") { session.showProjectBrowser = false; session.openProjectConfirmed(info.url) }
                                Button("Share…") { session.shareItem = ShareItem(url: info.url) }
                                Button("Delete", role: .destructive) { delete(info) }
                            }
                    }
                }
            }
        }
    }

    private func delete(_ info: ProjectInfo) {
        try? FileManager.default.removeItem(at: info.url)
        let audio = info.url.deletingLastPathComponent().appendingPathComponent(info.url.deletingPathExtension().lastPathComponent + " Audio")
        try? FileManager.default.removeItem(at: audio)
        RecentProjects.remove(info.url)
        library.refresh(includeOther: false)
    }
}
