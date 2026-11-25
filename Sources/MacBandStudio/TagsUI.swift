import SwiftUI

/// Asks about a tag whenever `session.renamingTagID` is set. A tag that was only just placed (a click on the lane, T, the Tags menu)
/// asks whether to add it, with its name; cancelling takes it away again. Double-click or Rename in its menu just asks for a new name.
struct TagRenameAlert: ViewModifier {
    @EnvironmentObject var session: Session
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(session.newTagPending ? "Add this tag?" : "Name this tag",
                   isPresented: Binding(get: { session.renamingTagID != nil }, set: { shown in
                       // dismissed some other way (Esc): a tag that wasn't confirmed is not added
                       if !shown, session.newTagPending, let id = session.renamingTagID { session.resolveNewTag(id, add: false, name: "") }
                       else if !shown { session.renamingTagID = nil }
                   })) {
                TextField("Name", text: $draft)
                Button(session.newTagPending ? "Add Tag" : "OK") {
                    guard let id = session.renamingTagID else { return }
                    if session.newTagPending { session.resolveNewTag(id, add: true, name: draft) }
                    else { session.renameTag(id, to: draft); session.renamingTagID = nil }
                }
                Button("Cancel", role: .cancel) {
                    if session.newTagPending, let id = session.renamingTagID { session.resolveNewTag(id, add: false, name: "") }
                    else { session.renamingTagID = nil }
                }
            } message: {
                Text(session.newTagPending ? "Tags mark a spot or an area of the song so you can find it again. Name it to add it, or cancel to leave it out."
                                           : "Tags mark a spot or an area of the song so you can find it again.")
            }
            .onChange(of: session.renamingTagID) { _, id in
                if let id, let t = session.project.tags.first(where: { $0.id == id }) { draft = t.name }
            }
    }
}
