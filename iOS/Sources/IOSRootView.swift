import SwiftUI

struct ButtonColorMenu: View {
    @ObservedObject private var theme = ButtonTheme.shared
    var body: some View {
        Picker("Button Color", selection: $theme.name) {
            ForEach(ButtonTheme.presets) { Text($0.id).tag($0.id) }
        }
    }
}

/// The whole app window. A phone (or any window that is small) shows one page at a time with tabs along the bottom; a big window
/// (iPad) shows the arrangement with the editor below it and the inspector beside it, like the Mac.
struct IOSRootView: View {
    @EnvironmentObject var session: Session
    @State private var editorHeight: CGFloat = 330

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 720 || geo.size.height < 520
            VStack(spacing: 0) {
                IOSTransportBar()
                Divider().overlay(Theme.line)
                if compact { CompactPages() } else { RegularLayout(editorHeight: $editorHeight) }
            }
            .environment(\.compactLayout, compact)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.window.ignoresSafeArea())
        .buttonStyle(VistaButtonStyle())
        .preferredColorScheme(.dark)
        .iosPresentations()
        .background {
            // keys on an iPad's keyboard
            Group {
                Button("") { session.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("") { session.rewind() }.keyboardShortcut(.return, modifiers: [])
                Button("") { session.undo() }.keyboardShortcut("z", modifiers: .command)
                Button("") { session.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                Button("") { session.save() }.keyboardShortcut("s", modifiers: .command)
                Button("") { session.openProject() }.keyboardShortcut("o", modifiers: .command)
                Button("") { session.metronome.toggle() }.keyboardShortcut("c", modifiers: [])
                Button("") { session.toggleRecord() }.keyboardShortcut("r", modifiers: [])
                Button("") { session.toggleLoop() }.keyboardShortcut("l", modifiers: [])
            }.opacity(0).allowsHitTesting(false)
        }
        .sheet(isPresented: $session.showProjectBrowser) { IOSProjectBrowser().environmentObject(session).preferredColorScheme(.dark) }
        .sheet(isPresented: Binding(get: { session.soundTarget != nil }, set: { if !$0 { session.soundTarget = nil } })) {
            if let t = session.soundTarget { SoundBrowserView(target: t).environmentObject(session).preferredColorScheme(.dark) }
        }
        .sheet(isPresented: Binding(get: { session.showInspector && sheetInspector }, set: { if !$0 { session.showInspector = false } })) {
            NavigationStack { InspectorView().navigationTitle("Inspector").navigationBarTitleDisplayMode(.inline) }
                .environmentObject(session).preferredColorScheme(.dark).presentationDetents([.medium, .large])
        }
        .overlay { if session.showIntro { IntroOverlay().environmentObject(session) } }
    }

    /// The inspector is a sheet when the layout is compact, and a column beside the editor otherwise.
    private var sheetInspector: Bool { UIScreen.main.bounds.width < 720 || UIScreen.main.bounds.height < 520 }
}

// MARK: - Phone layout

enum IOSPage: String, CaseIterable, Identifiable {
    case tracks = "Tracks", editor = "Piano Roll", steps = "Steps", score = "Score", visual = "Visual", tune = "Vocal Tune", mixer = "Mixer"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .tracks: return "rectangle.split.3x1"
        case .editor: return "pianokeys"
        case .steps: return "square.grid.3x3"
        case .score: return "music.note.list"
        case .visual: return "waveform"
        case .tune: return "mic"
        case .mixer: return "slider.vertical.3"
        }
    }
}

struct CompactPages: View {
    @EnvironmentObject var session: Session

    private var page: IOSPage {
        if !session.showEditor { return .tracks }
        switch session.bottomPanel {
        case .editor: return .editor
        case .steps: return .steps
        case .score: return .score
        case .visual: return .visual
        case .tune: return .tune
        case .mixer: return .mixer
        }
    }

    private func go(_ p: IOSPage) {
        switch p {
        case .tracks: session.showEditor = false
        case .editor: session.showEditor = true; session.bottomPanel = .editor
        case .steps: session.showEditor = true; session.bottomPanel = .steps
        case .score: session.showEditor = true; session.bottomPanel = .score
        case .visual: session.showEditor = true; session.bottomPanel = .visual
        case .tune: session.showEditor = true; session.bottomPanel = .tune
        case .mixer: session.showEditor = true; session.bottomPanel = .mixer
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if page == .tracks { ArrangementView() } else { BottomPanelContent() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.showKeyboard { Divider().overlay(Theme.line); IOSKeyboardDrawer() }
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                ForEach(IOSPage.allCases) { p in
                    Button { go(p) } label: {
                        VStack(spacing: 1) {
                            Image(systemName: p.symbol).font(.system(size: 14, weight: .semibold))
                            Text(p.rawValue).font(.system(size: 8.5, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(page == p ? 1 : 0.62))
                        .frame(maxWidth: .infinity).frame(height: 34)
                        .vistaBackground(state: page == p)
                    }.buttonStyle(.plain).padding(.horizontal, 1).padding(.vertical, 2)
                }
            }
            .background(Theme.panel)
        }
    }
}

// MARK: - iPad layout

struct RegularLayout: View {
    @EnvironmentObject var session: Session
    @Binding var editorHeight: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ArrangementView()
                if session.showEditor {
                    Rectangle().fill(Theme.line).frame(height: 1)
                        .overlay(Color.clear.frame(height: 22).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { v in
                                    if start == nil { start = editorHeight }
                                    editorHeight = min(560, max(180, start! - v.translation.height))
                                }.onEnded { _ in start = nil }))
                    BottomPanelView().frame(height: editorHeight)
                }
            }
            if session.showInspector {
                Divider().overlay(Theme.line)
                InspectorView().frame(width: 280)
            }
        }
    }
}
