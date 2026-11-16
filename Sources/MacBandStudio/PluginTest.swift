import Foundation
#if canImport(AppKit)
import AppKit
import AVFoundation

/// `--plugintest`: plugins that can't be used are listed with the reason instead of silently missing.
@MainActor
enum PluginTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) {
        print((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func run() -> Int32 {
        let arm = NSBundleExecutableArchitectureARM64, intel = NSBundleExecutableArchitectureX86_64
        let i386 = NSBundleExecutableArchitectureI386, ppc = NSBundleExecutableArchitecturePPC
        check(PluginLibrary.unusableReason(archs: [arm], hasAudioComponents: true) == nil, "an Apple-silicon plugin is fine")
        check(PluginLibrary.unusableReason(archs: [arm, intel], hasAudioComponents: true) == nil, "…and so is a universal one")
        check(PluginLibrary.unusableReason(archs: [intel], hasAudioComponents: true)?.contains("Intel-only") == true, "Intel-only: said so")
        check(PluginLibrary.unusableReason(archs: [i386, ppc], hasAudioComponents: false)?.contains("32-bit / PowerPC") == true, "a 2008 i386 + PowerPC plugin: said so")
        check(PluginLibrary.unusableReason(archs: [arm], hasAudioComponents: false)?.contains("old-format") == true, "an Audio Unit without a registration entry: said so")

        // a real look at the plugin folders: whatever macOS didn't register is explained
        let known = Set(AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription()).compactMap { $0.componentURL?.path })
        let strays = PluginLibrary.unregisteredAUs(registered: known)
        print("components macOS doesn't register (with the reasons):", strays)
        let tal = PluginFolders.components.appendingPathComponent("TAL-Bitcrusher.component")
        if FileManager.default.fileExists(atPath: tal.path), !PluginHost.isQuarantined(tal.path) {
            check(strays.contains { $0.hasPrefix("TAL-Bitcrusher.component") && $0.contains("32-bit") }, "TAL-Bitcrusher (2008, 32-bit) is reported as such")
        }
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
#endif
