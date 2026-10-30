import Foundation
import AVFoundation
import SwiftUI

// Plugin hosting (VST3 and Audio Unit plugins) is a Mac feature. These keep the code shared with the Mac app compiling:
// there are simply never any plugins on iOS, and a track that used one plays its General MIDI sound instead.

struct LibraryPlugin: Identifiable, Hashable {
    var spec: PluginSpec
    var path: String
    var id: String { spec.key }
}

@MainActor
final class PluginLibrary: ObservableObject {
    static let shared = PluginLibrary()
    @Published var plugins: [LibraryPlugin] = []
    @Published var scanning = false
    @Published var skipped: [String] = []
    @Published var blocked: [URL] = []
    var instruments: [LibraryPlugin] { [] }
    var effects: [LibraryPlugin] { [] }
    func rescan() {}
    enum InstallResult { case installed(URL), failed(String) }
    func install(_ urls: [URL], replace: (String) -> Bool) -> [InstallResult] { [] }
}

enum PluginHost {
    static func fourCC(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    static func instantiate(_ spec: PluginSpec) async throws -> AVAudioUnit {
        throw EngineError.message("\(spec.name) can't be used on iOS.")
    }
    static func captureState(_ unit: AVAudioUnit) -> Data? { nil }
}

@MainActor
final class PluginWindows {
    static let shared = PluginWindows()
    func discard(_ ids: [UUID]) {}
    func closeAll() {}
    func installFullscreenSupport() {}
    func open(unit: AVAudioUnit, title: String, key: UUID) {}
}

@MainActor
enum EventLog {
    static func installIfRequested() {}
}
