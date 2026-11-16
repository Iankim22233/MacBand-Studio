import SwiftUI

struct BusyOverlay: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 12) { ProgressView(); Text(message).font(.system(size: 13)) }
                .padding(28).background(Rectangle().fill(Theme.raised))
        }
    }
}

/// The big count shown before recording starts.
struct CountdownOverlay: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Text(text).font(.system(size: 120, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
            Text("Recording starts…").font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 54).padding(.vertical, 28)
        .background(Rectangle().fill(Color.black.opacity(0.62)))
        .overlay(Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 1))
        .id(text)
        .transition(.scale(scale: 1.25).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}

struct BottomPanelView: View {
    @EnvironmentObject var session: Session
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(BottomPanel.allCases) { p in
                    Button { session.bottomPanel = p } label: {
                        Text(p.rawValue).font(Theme.vista(11))
                            .foregroundStyle(.white.opacity(session.bottomPanel == p ? 1 : 0.8))

                            .padding(.horizontal, 14).frame(height: 24)
                            .vistaBackground(state: session.bottomPanel == p)
                    }.buttonStyle(.plain).padding(.leading, 4).padding(.vertical, 2)
                }
                Spacer()
            }
            .background(Theme.panel)
            Divider().overlay(Theme.line)
            BottomPanelContent()
        }
        .background(Theme.panel)
    }
}

/// The panel that is chosen: piano roll, step sequencer, score, visualizer, vocal tune or mixer.
struct BottomPanelContent: View {
    @EnvironmentObject var session: Session
    var body: some View {
        switch session.bottomPanel {
        case .editor: PianoRollContainer()
        case .steps: StepSequencerContainer()
        case .score: ScoreContainer()
        case .visual: VisualizerContainer()
        case .tune: TuneContainer()
        case .mixer: MixerView()
        }
    }
}
