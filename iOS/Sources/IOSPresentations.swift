import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Shows what the session asks for: alerts and questions, file pickers, the share sheet, the error message, the toast, and the busy overlay.
struct IOSPresentations: ViewModifier {
    @EnvironmentObject var session: Session
    @State private var promptText = ""
    @State private var shownPrompt: UUID?

    func body(content: Content) -> some View {
        content
            .overlay { if let m = session.busyMessage { BusyOverlay(message: m).ignoresSafeArea() } }
            .overlay(alignment: .bottom) {
                if let t = session.toast {
                    Text(t).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(Rectangle().fill(Theme.raised)).overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                        .padding(.bottom, 56).padding(.horizontal, 20).transition(.opacity).allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: session.toast)
            .alert(session.prompt?.title ?? "", isPresented: Binding(get: { session.prompt != nil }, set: { if !$0 && session.prompt?.id == shownPrompt { session.prompt = nil } }), presenting: session.prompt) { p in
                if let ph = p.textFieldPlaceholder {
                    TextField(ph, text: $promptText).autocorrectionDisabled()
                        .keyboardType(ph == "BPM" ? .decimalPad : .default)
                }
                ForEach(Array(p.choices.enumerated()), id: \.offset) { i, c in
                    Button(c.title, role: c.role) {
                        let text = promptText
                        session.prompt = nil
                        // after the alert has gone, so an answer can ask the next question
                        DispatchQueue.main.async {
                            if i == 0, let onText = p.onText { onText(text) }
                            c.action()
                        }
                    }
                }
            } message: { p in Text(p.message) }
            .onChange(of: session.prompt?.id) { _, id in
                shownPrompt = id
                promptText = session.prompt?.textFieldInitial ?? ""
            }
            .alert("MacBand Studio", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
                Button("OK") { session.errorMessage = nil }
            } message: { Text(session.errorMessage ?? "") }
            .fileImporter(isPresented: Binding(get: { session.filePicker != nil }, set: { if !$0 { session.filePicker = nil } }),
                          allowedContentTypes: session.filePicker?.types ?? [.data], allowsMultipleSelection: session.filePicker?.allowsMultiple ?? false) { result in
                let request = session.filePicker
                session.filePicker = nil
                guard let request, case .success(let urls) = result else { return }
                let copies = urls.compactMap { Self.localCopy(of: $0) }
                if !copies.isEmpty { DispatchQueue.main.async { request.completion(copies) } }
            }
            .sheet(item: $session.shareItem) { item in ShareSheet(url: item.url).ignoresSafeArea() }
    }

    /// Picked files belong to other apps or iCloud: read them once, into a folder of our own.
    static func localCopy(of url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("picked-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        var coordinatorError: NSError?
        var result: URL?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: dest); result = dest } catch { NSLog("MacBand: couldn't read \(url.lastPathComponent): \(error)") }
        }
        return result
    }
}

extension View {
    func iosPresentations() -> some View { modifier(IOSPresentations()) }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
