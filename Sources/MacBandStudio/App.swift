import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MacBandApp: App {
    @StateObject private var session = Session()

    var body: some Scene {
        Window("MacBand Studio", id: "main") {
            ContentView()
                .environmentObject(session)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 620)
                .onOpenURL { url in session.handleDrop([url]) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { session.newProject() }.keyboardShortcut("n")
                Button("Open…") { session.openProject() }.keyboardShortcut("o")
                Button("Open File…") { session.openProjectFromPanel() }.keyboardShortcut("o", modifiers: [.command, .option])
                Divider()
                Button("Save") { session.save() }.keyboardShortcut("s")
                Toggle("Auto Save", isOn: Binding(get: { session.autoSaveEnabled }, set: { session.autoSaveEnabled = $0 }))
                Button("Export Band Project…") { session.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Menu("Import") {
                    Button("MIDI File…") { session.importMIDI() }.keyboardShortcut("i")
                    Button("Audio File…") { session.importAudio() }.keyboardShortcut("i", modifiers: [.command, .shift])
                    Button("Band Project…") { session.importBandProject() }
                }
                Menu("Export") {
                    Button("MIDI File…") { session.exportMIDI() }.keyboardShortcut("e")
                    Button("Audio (WAV)…") { session.exportAudio() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("Band Project…") { session.saveAs() }
                    Divider()
                    Button("Sheet Music (PDF)…") { session.exportScorePDF() }
                    Button("Sheet Music (MusicXML)…") { session.exportScoreMusicXML() }
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { session.undo() }.keyboardShortcut("z").disabled(!session.canUndo)
                Button("Redo") { session.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
            }
            CommandMenu("Track") {
                Button("New Instrument Track") { session.addTrack() }.keyboardShortcut("t")
                Button("New Track from Sound Library…") { session.soundTarget = .newTrack }.keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Change Sound…") { if let t = session.selectedTrackID { session.soundTarget = .track(t) } }.keyboardShortcut("b")
                Button("Duplicate Track") { if let t = session.selectedTrackID { session.duplicateTrack(t) } }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Delete Track") { if let t = session.selectedTrackID { session.deleteTrack(t) } }
                Divider()
                Divider()
                Button("Auto Balance Levels") { session.autoBalance() }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Reset Track Trims") { session.resetTrims() }
                Toggle("Balance Levels After MIDI Import", isOn: Binding(get: { session.autoBalanceOnImport }, set: { session.autoBalanceOnImport = $0 }))
                Divider()
                Button("Plugin Manager…") { session.showPluginManager = true }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Show Introduction") { session.startIntro() }
                Button("Show the MacBand Folder") { NSWorkspace.shared.open(ProjectsFolder.ensure().url) }
            }
            CommandMenu("View") {
                Button("Visualizer Window") { VisualizerWindow.shared.show(session) }.keyboardShortcut("v", modifiers: [.command, .option])
                Divider()
                ButtonColorMenu()
            }
            CommandMenu("Transport") {
                Button("Play / Stop") { session.togglePlay() }
                Button("Go to Start") { session.rewind() }
                Button("Record") { session.toggleRecord() }
                Button("Loop") { session.toggleLoop() }
                Button("Metronome") { session.metronome.toggle() }
                Divider()
                Button("Musical Typing") { session.musicalTyping.toggle() }.keyboardShortcut("k")
            }
        }
    }
}

/// View ▸ Button Color: the Vista buttons use red as a placeholder; pick any other colour here.
struct ButtonColorMenu: View {
    @ObservedObject private var theme = ButtonTheme.shared
    var body: some View {
        Picker("Button Color", selection: $theme.name) {
            ForEach(ButtonTheme.presets) { Text($0.id).tag($0.id) }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var session: Session
    @State private var editorHeight: CGFloat = 400
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ArrangementView()
                    if session.showEditor {
                        ResizeHandle(height: $editorHeight)
                        BottomPanelView().frame(height: editorHeight)
                    }
                }
                if session.showInspector {
                    Divider().overlay(Theme.line)
                    InspectorView().frame(width: 264)
                }
            }
        }
        .buttonStyle(VistaButtonStyle())
        .background(Theme.window)
        .background(WindowConfigurator())
        .overlay { if let m = session.busyMessage { BusyOverlay(message: m) } }
        .overlay(alignment: .bottom) {
            if let t = session.toast {
                Text(t).font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Rectangle().fill(Theme.raised)).overlay(Rectangle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .padding(.bottom, 24).transition(.opacity).allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.toast)
        .overlay { if dropTargeted { Rectangle().stroke(Theme.accent, lineWidth: 2).padding(4).allowsHitTesting(false) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { session.handleDrop([url]) } }
                }
            }
            return true
        }
        .sheet(isPresented: $session.showPluginManager) { PluginManagerView().environmentObject(session) }
        .sheet(isPresented: $session.showProjectBrowser) { ProjectBrowserView().environmentObject(session) }
        .overlay { if session.showIntro { IntroOverlay().environmentObject(session) } }
        .sheet(isPresented: Binding(get: { session.soundTarget != nil }, set: { if !$0 { session.soundTarget = nil } })) {
            if let t = session.soundTarget { SoundBrowserView(target: t).environmentObject(session) }
        }
        .alert("MacBand Studio", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK") { session.errorMessage = nil }
        } message: { Text(session.errorMessage ?? "") }
    }
}

struct ResizeHandle: View {
    @Binding var height: CGFloat
    @State private var start: CGFloat?
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
            .overlay(Color.clear.frame(height: 9).contentShape(Rectangle()).onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }.gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if start == nil { start = height }
                    height = min(640, max(200, start! - v.translation.height))
                }.onEnded { _ in start = nil }))
    }
}
