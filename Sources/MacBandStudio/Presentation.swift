import SwiftUI
import UniformTypeIdentifiers

// Questions, file pickers and share sheets that the iOS app shows over the window. (The Mac uses its own panels and alerts;
// these are only ever set on iOS, where the root view presents them.)

/// A message or question shown as an alert.
struct Prompt: Identifiable {
    struct Choice {
        var title: String
        var role: ButtonRole? = nil
        var action: () -> Void = {}
    }
    let id = UUID()
    var title: String
    var message: String
    var choices: [Choice]
    /// When set the alert has a text field (for a name); the first choice's action then gets the text through `onText`.
    var textFieldPlaceholder: String? = nil
    var textFieldInitial = ""
    var onText: ((String) -> Void)? = nil
}

/// Asks the person to pick files. The completion gets local copies that can be read freely.
struct FilePickerRequest: Identifiable {
    let id = UUID()
    var types: [UTType]
    var allowsMultiple = false
    var completion: ([URL]) -> Void
}

/// A file offered to the share sheet (Save to Files, AirDrop, Mail…).
struct ShareItem: Identifiable {
    let id = UUID()
    var url: URL
}

/// The environment flag the layouts read: true on a phone-sized window (always false on the Mac).
private struct CompactLayoutKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}
