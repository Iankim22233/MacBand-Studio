import Foundation

/// General MIDI percussion map: which note plays which drum on a GM kit (most kits follow it).
enum DrumMap {
    static let names: [Int: String] = [
        27: "High Q", 28: "Slap", 29: "Scratch Push", 30: "Scratch Pull", 31: "Sticks", 32: "Square Click", 33: "Metronome Click", 34: "Metronome Bell",
        35: "Kick 2", 36: "Kick", 37: "Side Stick", 38: "Snare", 39: "Hand Clap", 40: "Snare 2",
        41: "Low Floor Tom", 42: "Closed Hi-Hat", 43: "High Floor Tom", 44: "Pedal Hi-Hat", 45: "Low Tom", 46: "Open Hi-Hat",
        47: "Low-Mid Tom", 48: "Hi-Mid Tom", 49: "Crash", 50: "High Tom", 51: "Ride", 52: "China Cymbal", 53: "Ride Bell",
        54: "Tambourine", 55: "Splash", 56: "Cowbell", 57: "Crash 2", 58: "Vibraslap", 59: "Ride 2",
        60: "Hi Bongo", 61: "Low Bongo", 62: "Mute Hi Conga", 63: "Open Hi Conga", 64: "Low Conga", 65: "High Timbale", 66: "Low Timbale",
        67: "High Agogo", 68: "Low Agogo", 69: "Cabasa", 70: "Maracas", 71: "Short Whistle", 72: "Long Whistle",
        73: "Short Guiro", 74: "Long Guiro", 75: "Claves", 76: "Hi Wood Block", 77: "Low Wood Block",
        78: "Mute Cuica", 79: "Open Cuica", 80: "Mute Triangle", 81: "Open Triangle",
        82: "Shaker", 83: "Jingle Bell", 84: "Bell Tree", 85: "Castanets", 86: "Mute Surdo", 87: "Open Surdo",
    ]

    static func name(_ pitch: Int) -> String? { names[pitch] }

    /// Name for display; unmapped notes fall back to their note name.
    static func label(_ pitch: Int) -> String { names[pitch] ?? Pitch.name(pitch) }

    /// The drums a step sequencer starts with, top to bottom.
    static let stepRows: [Int] = [49, 46, 42, 51, 39, 38, 37, 48, 45, 41, 36, 56]

    enum Family { case kick, snare, hat, tom, cymbal, percussion }
    static func family(_ p: Int) -> Family {
        switch p {
        case 35, 36: return .kick
        case 37, 38, 39, 40: return .snare
        case 42, 44, 46: return .hat
        case 41, 43, 45, 47, 48, 50: return .tom
        case 49, 51, 52, 53, 55, 57, 59: return .cymbal
        default: return .percussion
        }
    }
}
