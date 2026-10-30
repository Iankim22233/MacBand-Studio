import Foundation
import SwiftUI

extension Session {
    /// After importing a MIDI file, level the tracks automatically (sounds differ a lot in how loud they are).
    var autoBalanceOnImport: Bool {
        get { UserDefaults.standard.object(forKey: "autoBalanceOnImport") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoBalanceOnImport") }
    }

    /// Measures every instrument track and sets each track's trim so they sit at the same loudness.
    /// Synchronous (renders the start of the song offline); returns how many tracks were adjusted.
    @discardableResult
    func balanceLevels(seconds: Double? = nil) throws -> Int {
        if transport.isPlaying { stop() }
        let proj = project
        let secs = seconds ?? min(60, max(8, proj.seconds(atBeat: proj.contentEnd)))
        // 1) measure each track on its own, level them against each other
        let loud = try engine.measureLoudness(proj, seconds: secs)
        let drums = Set(proj.tracks.filter { $0.instrument.isDrums }.map { $0.id })
        let relative = AutoBalance.relativeTrims(loudness: loud, drums: drums)
        guard !relative.isEmpty else { return 0 }
        // 2) measure the whole mix with those trims (tracks that play the same notes add up louder than apart),
        //    then move it to the target loudness
        var trial = proj
        for i in trial.tracks.indices { if let r = relative[trial.tracks[i].id] { trial.tracks[i].trim = min(AutoBalance.maxBoost, max(AutoBalance.maxCut, r)) } }
        let mix = try engine.measureMix(trial, seconds: secs, keepTrims: true).master
        let trims = mix.map { AutoBalance.finalTrims(relative: relative, measuredMix: $0) } ?? AutoBalance.trims(loudness: loud, drums: drums)
        edit { p in
            for i in p.tracks.indices { if let t = trims[p.tracks[i].id] { p.tracks[i].trim = t } }
        }
        sequenceDirty = true; flushSequence()
        return trims.count
    }

    /// Menu / button action: same thing with a progress overlay.
    func autoBalance(quiet: Bool = false) {
        guard !project.tracks.isEmpty, busyMessage == nil else { return }
        if transport.isPlaying { stop() }
        busyMessage = "Balancing levels…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
            defer { busyMessage = nil }
            do {
                let n = try balanceLevels()
                if n > 0 { showToast("Balanced the levels of \(n) track\(n == 1 ? "" : "s")") }
                else if !quiet { showToast("Nothing to balance yet: no track is making sound at the start") }
            } catch { if !quiet { errorMessage = "Couldn't balance the levels: \(error.localizedDescription)" } }
        }
    }

    func resetTrims() {
        guard project.tracks.contains(where: { $0.trim != 0 }) else { return }
        edit { p in for i in p.tracks.indices { p.tracks[i].trim = 0 } }
        showToast("Trims reset")
    }

    /// Waits for the instruments of a freshly imported file to finish loading, then balances them.
    func balanceAfterLoading() {
        Task { @MainActor in
            for _ in 0..<240 {
                let ready = engine.strips.count >= project.tracks.count && engine.strips.values.allSatisfy { !$0.loading }
                if ready { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            autoBalance(quiet: true)
        }
    }
}
