import SwiftUI

/// Asks for a tag's name whenever `session.renamingTagID` is set (a new tag, double-click, or Rename in its menu).
struct TagRenameAlert: ViewModifier {
    @EnvironmentObject var session: Session
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert("Name this tag", isPresented: Binding(get: { session.renamingTagID != nil }, set: { if !$0 { session.renamingTagID = nil } })) {
                TextField("Name", text: $draft)
                Button("OK") { if let id = session.renamingTagID { session.renameTag(id, to: draft) }; session.renamingTagID = nil }
                Button("Cancel", role: .cancel) { session.renamingTagID = nil }
            } message: { Text("Tags mark a spot or an area of the song so you can find it again.") }
            .onChange(of: session.renamingTagID) { _, id in
                if let id, let t = session.project.tags.first(where: { $0.id == id }) { draft = t.name }
            }
    }
}
