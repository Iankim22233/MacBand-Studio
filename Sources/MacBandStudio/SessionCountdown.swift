import Foundation

/// The count-in: before recording starts the screen counts the bar down ("4/4", "3/4", "2/4", "1/4", one per beat, with a click),
/// then recording begins on the next downbeat. Record, Space or Esc during the count calls it off.
extension Session {
    func startCountdown(then go: @escaping () -> Void) {
        cancelCountdown()
        let labels = Countdown.labels(beats: Int(project.beatsPerBar.rounded()))
        let beat = 60 / max(20, project.bpm(at: transport.beat))
        engine.countInBegin()
        countdown = labels[0]                                       // the first beat is on screen (and clicks) the moment Record is pressed
        engine.countInClick(accent: true)
        countdownTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            let t0 = clock.now
            for (i, label) in labels.enumerated() {
                guard let self, !Task.isCancelled else { return }
                if i > 0 { self.countdown = label; self.engine.countInClick(accent: false) }
                try? await clock.sleep(until: t0 + .seconds(beat * Double(i + 1)))      // against the clock, so the beats don't drift
            }
            guard let self, !Task.isCancelled else { return }
            self.countdown = nil
            self.countdownTask = nil
            self.engine.countInEnd()
            go()
        }
    }

    func cancelCountdown() {
        guard countdownTask != nil || countdown != nil else { return }
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
        engine.countInEnd()
    }
}
