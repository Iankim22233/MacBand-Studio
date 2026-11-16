import Foundation

/// Tags: names put on a spot or an area of the timeline to mark it (a verse, a mistake to fix, a place to come back to).
extension Session {
    private func sortTags(_ p: inout Project) { p.tags.sort { ($0.start, $0.end) < ($1.start, $1.end) } }

    /// Puts a tag at `start`; `length` 0 marks a spot, more marks an area. Returns its id.
    @discardableResult
    func addTag(start: Double, length: Double = 0, name: String? = nil, ask: Bool = true) -> UUID {
        let tag = Tag(name: name ?? "Tag \(project.tags.count + 1)", start: max(0, start), length: max(0, length))
        edit { p in p.tags.append(tag); self.sortTags(&p) }
        selectedTagID = tag.id
        if ask { renamingTagID = tag.id }
        return tag.id
    }

    /// A tag over the loop area, if there is one.
    func tagLoopArea() {
        guard project.loopEnd > project.loopStart else { return }
        addTag(start: project.loopStart, length: project.loopEnd - project.loopStart)
    }

    func renameTag(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, project.tags.first(where: { $0.id == id })?.name != n else { return }
        edit { p in if let i = p.tags.firstIndex(where: { $0.id == id }) { p.tags[i].name = n } }
    }

    func cycleTagColor(_ id: UUID) {
        edit { p in if let i = p.tags.firstIndex(where: { $0.id == id }) { p.tags[i].colorIndex = (p.tags[i].colorIndex + 1) % Palette.trackColors.count } }
    }

    func deleteTag(_ id: UUID) {
        edit { p in p.tags.removeAll { $0.id == id } }
        if selectedTagID == id { selectedTagID = nil }
    }

    func clearTags() { guard !project.tags.isEmpty else { return }; edit { $0.tags = [] }; selectedTagID = nil }

    /// Loops the area a tag covers.
    func loopTag(_ id: UUID) {
        guard let t = project.tags.first(where: { $0.id == id }), t.isArea else { return }
        edit { $0.loopStart = t.start; $0.loopEnd = t.end; $0.loopEnabled = true }
    }

    /// Moves the playhead to the next / previous tag.
    func jumpToTag(forward: Bool) {
        let now = transport.beat
        let starts = project.tags.map { $0.start }
        let target = forward ? starts.filter { $0 > now + 1e-6 }.min() : starts.filter { $0 < now - 1e-6 }.max()
        if let target { seek(to: target); selectedTagID = project.tags.first { $0.start == target }?.id }
    }

    /// Writes the tags back into a sorted list after one was dragged.
    func resortTags() { modify { self.sortTags(&$0) } }
}
