import Foundation
import AppKit

// Child-process mode used by the plugin scanner: print the classes in one VST3 bundle as JSON.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--scan-vst3" {
    print(VST3Support.scanBundleJSON(path: CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.contains("--selftest") {
    MainActor.assumeIsolated { SelfTest.run() }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--importtest"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { UITest.importTest(CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--tempochange"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { InstrumentChangeTest.tempoRun(CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--livetempo"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { InstrumentChangeTest.liveTempo(CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--tempofuzz"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { InstrumentChangeTest.tempoFuzz(CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--looptempo"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { InstrumentChangeTest.loopTempo(CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--balancerace"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { InstrumentChangeTest.balanceRace(CommandLine.arguments[i + 1]) }
    exit(0)
}
if CommandLine.arguments.contains("--tempodelete") {
    MainActor.assumeIsolated { InstrumentChangeTest.tempoDelete() }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--instchange"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { InstrumentChangeTest.run(CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--manytracks"), i + 1 < CommandLine.arguments.count, let n = Int(CommandLine.arguments[i + 1]) {
    MainActor.assumeIsolated { UITest.manyTracks(n) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--truncimport"), i + 3 < CommandLine.arguments.count {
    MainActor.assumeIsolated { UITest.truncImport(CommandLine.arguments[i + 1], tracks: Int(CommandLine.arguments[i + 2]) ?? 1, notes: Int(CommandLine.arguments[i + 3]) ?? 100) }
    exit(0)
}
if CommandLine.arguments.contains("--transcribetest") {
    Task { await TuneTest.transcribeTest(); exit(0) }
    RunLoop.main.run()
}
if CommandLine.arguments.contains("--audiotest") {
    MainActor.assumeIsolated { TuneTest.sessionTest() }
    exit(0)
}
if CommandLine.arguments.contains("--tunetest") {
    MainActor.assumeIsolated { TuneTest.run() }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--stresstest"), i + 1 < CommandLine.arguments.count {
    let rounds = i + 2 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 2]) ?? 40 : 40
    MainActor.assumeIsolated { StressTest.run(CommandLine.arguments[i + 1], rounds: rounds) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--visualshots"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { VisualizerTest.shots(CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--introshots"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { ProjectTest.introShots(CommandLine.arguments[i + 1]) }
    exit(0)
}
if CommandLine.arguments.contains("--bandtest") { exit(MainActor.assumeIsolated { GarageBandTest.run() }) }
if CommandLine.arguments.contains("--wavebench") { MainActor.assumeIsolated { WaveBench.run() }; exit(0) }
if CommandLine.arguments.contains("--headertest") { exit(MainActor.assumeIsolated { HeaderClickTest.run() }) }
if CommandLine.arguments.contains("--projecttest") { exit(MainActor.assumeIsolated { ProjectTest.run() }) }
if CommandLine.arguments.contains("--autosavetest") { exit(MainActor.assumeIsolated { AutosaveTest.run() }) }
if CommandLine.arguments.contains("--visualtest") { exit(MainActor.assumeIsolated { VisualizerTest.run() }) }
if CommandLine.arguments.contains("--soundtest-after") { exit(MainActor.assumeIsolated { SoundTest.afterOffline() }) }
if CommandLine.arguments.contains("--balancetest") { exit(MainActor.assumeIsolated { BalanceTest.run() }) }
if CommandLine.arguments.contains("--toolstest") { exit(MIDIToolsTest.run()) }
if CommandLine.arguments.contains("--scoreuitest") {
    MainActor.assumeIsolated { ScoreTest.ui() }
    exit(MainActor.assumeIsolated { ScoreTest.failures == 0 ? Int32(0) : Int32(1) })
}
if let i = CommandLine.arguments.firstIndex(of: "--scoreexport"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { ScoreTest.export(CommandLine.arguments[i + 1]) }
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--scoreshots"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { ScoreTest.shots(CommandLine.arguments[i + 1]) }
    exit(0)
}
if CommandLine.arguments.contains("--scoretest") {
    MainActor.assumeIsolated { ScoreTest.run() }
    exit(MainActor.assumeIsolated { ScoreTest.failures == 0 ? Int32(0) : Int32(1) })
}
if CommandLine.arguments.contains("--steptest") {
    MainActor.assumeIsolated { StepTest.run() }
}
if CommandLine.arguments.contains("--soundtest-live") {
    MainActor.assumeIsolated { SoundTest.live() }
    exit(0)
}
if CommandLine.arguments.contains("--soundtest") {
    MainActor.assumeIsolated { SoundTest.run() }
    exit(MainActor.assumeIsolated { SoundTest.failures == 0 ? Int32(0) : Int32(1) })
}
if CommandLine.arguments.contains("--uitest") {
    MainActor.assumeIsolated { UITest.run() }
    exit(MainActor.assumeIsolated { UITest.failures == 0 ? Int32(0) : Int32(1) })
}
MacBandApp.main()
