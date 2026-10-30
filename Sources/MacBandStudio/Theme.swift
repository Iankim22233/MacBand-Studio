import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum Theme {
    static let ns = (
        window: NSColor(red: 0.105, green: 0.110, blue: 0.125, alpha: 1),
        panel: NSColor(red: 0.135, green: 0.140, blue: 0.158, alpha: 1),
        raised: NSColor(red: 0.175, green: 0.182, blue: 0.205, alpha: 1),
        well: NSColor(red: 0.085, green: 0.088, blue: 0.100, alpha: 1),
        line: NSColor(white: 1, alpha: 0.07),
        lineStrong: NSColor(white: 1, alpha: 0.14),
        text: NSColor(white: 0.92, alpha: 1),
        dim: NSColor(white: 0.58, alpha: 1),
        faint: NSColor(white: 0.38, alpha: 1),
        accent: NSColor.controlAccentColor
    )
    static let window = Color(nsColor: ns.window)
    static let panel = Color(nsColor: ns.panel)
    static let raised = Color(nsColor: ns.raised)
    static let well = Color(nsColor: ns.well)
    static let line = Color(nsColor: ns.line)
    static let text = Color(nsColor: ns.text)
    static let dim = Color(nsColor: ns.dim)
    static let faint = Color(nsColor: ns.faint)
    /// The app's main colour follows the system accent (System Settings ▸ Appearance ▸ Accent color).
    static var accentNS: NSColor { NSColor.controlAccentColor }
    static var accent: Color { Color(nsColor: NSColor.controlAccentColor) }
    /// Button / label face: Tahoma, the clean upright UI font of the Vista era (Segoe UI isn't on macOS).
    static func vista(_ size: CGFloat) -> Font { .custom("Tahoma", size: size) }
    static let lcd = Font.system(size: 20, weight: .medium, design: .monospaced)
    static let small = Font.system(size: 11)
    static let label = Font.system(size: 10, weight: .semibold)
}

// MARK: - Vista-style buttons

/// The colour of every button. It follows the system accent (highlight) colour; View ▸ Button Color can pick a fixed one.
final class ButtonTheme: ObservableObject {
    static let shared = ButtonTheme()
    struct Preset: Identifiable { let id: String; let color: NSColor? }   // nil colour = follow the system accent
    static let presets: [Preset] = [
        Preset(id: "System Accent", color: nil),
        Preset(id: "Red", color: NSColor(red: 0.92, green: 0.26, blue: 0.22, alpha: 1)),
        Preset(id: "Blue", color: NSColor(red: 0.16, green: 0.45, blue: 0.90, alpha: 1)),
        Preset(id: "Green", color: NSColor(red: 0.18, green: 0.68, blue: 0.30, alpha: 1)),
        Preset(id: "Orange", color: NSColor(red: 0.95, green: 0.50, blue: 0.10, alpha: 1)),
        Preset(id: "Purple", color: NSColor(red: 0.55, green: 0.32, blue: 0.85, alpha: 1)),
        Preset(id: "Graphite", color: NSColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1)),
    ]
    @Published var name: String { didSet { UserDefaults.standard.set(name, forKey: "buttonColor") } }
    init() {
        name = UserDefaults.standard.string(forKey: "buttonColor") ?? "System Accent"
        // Repaint the buttons when the accent colour is changed in System Settings.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.objectWillChange.send() }
    }
    var base: NSColor { (Self.presets.first { $0.id == name } ?? Self.presets[0]).color ?? NSColor.controlAccentColor }
}

extension NSColor {
    /// Blend toward another colour (0 = self, 1 = other) in sRGB.
    func mixed(_ other: NSColor, _ t: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self, b = other.usingColorSpace(.sRGB) ?? other
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }
}

private struct VistaTintKey: EnvironmentKey { static let defaultValue: NSColor? = nil }
extension EnvironmentValues {
    /// When set, buttons, sliders and toggles in this part of the window use this colour instead of the system accent
    /// (the Inspector and mixer strips set it to the colour of the instrument they show).
    var vistaTint: NSColor? {
        get { self[VistaTintKey.self] }
        set { self[VistaTintKey.self] = newValue }
    }
}

/// A sharp square with a white frame and a vertical gradient, light at the top and saturated at the bottom.
/// `state`: nil = push button, false = toggle that is off (muted), true = toggle that is on (vivid + glow).
struct VistaFace: View {
    var state: Bool? = nil
    var base: NSColor? = nil
    var pressed = false
    var hover = false
    var enabled = true
    var glow: Double = 0                 // 0…1: brightens the face (a live level)
    var border: CGFloat = 1
    @ObservedObject private var theme = ButtonTheme.shared
    @Environment(\.vistaTint) private var tint
    var body: some View {
        var c = base ?? tint ?? theme.base
        if state == false { c = c.mixed(NSColor(white: 0.16, alpha: 1), 0.62) }
        if !enabled { c = NSColor(white: 0.34, alpha: 1) }
        if pressed { c = c.mixed(.black, 0.22) } else if hover && enabled { c = c.mixed(.white, 0.14) }
        if glow > 0.001 && enabled { c = c.mixed(.white, CGFloat(min(1, glow)) * 0.62) }
        let top = c.mixed(.white, state == false ? 0.28 : 0.58), bottom = c
        let frame = Color.white.opacity(!enabled ? 0.28 : (state == false ? 0.55 : 1))
        return ZStack {
            Rectangle().fill(LinearGradient(colors: [Color(nsColor: top), Color(nsColor: bottom)], startPoint: .top, endPoint: .bottom))
            if state == true { Rectangle().strokeBorder(Color(nsColor: c.mixed(.white, 0.5)).opacity(0.9), lineWidth: border + 1.5).blur(radius: 1.5).opacity(0.5) }
            if glow > 0.02 && enabled {
                Rectangle().fill(LinearGradient(colors: [Color.white.opacity(0.35 * glow), Color.white.opacity(0.0)], startPoint: .top, endPoint: .center))
                Rectangle().strokeBorder(Color.white.opacity(0.85 * glow), lineWidth: 3).blur(radius: 2.5)
            }
            Rectangle().strokeBorder(frame, lineWidth: border)
        }
        .clipShape(Rectangle())
    }
}

extension View {
    /// Escape (Mac) ends an edit; a touch screen has no such key.
    @ViewBuilder func onEscape(_ perform: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: perform)
        #else
        self
        #endif
    }

    /// Gives any label the Vista button face.
    func vistaBackground(state: Bool? = nil, base: NSColor? = nil, border: CGFloat = 1) -> some View {
        background(VistaFace(state: state, base: base, border: border))
    }
}

struct VistaButtonStyle: ButtonStyle {
    var compact = true
    var state: Bool? = nil
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, compact: compact, state: state) }
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        let state: Bool?
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            configuration.label
                .font(Theme.vista(compact ? 11 : 12))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.55))
                .padding(.horizontal, compact ? 10 : 14).frame(minHeight: compact ? 22 : 28)
                .background(VistaFace(state: state, pressed: configuration.isPressed, hover: hover, enabled: enabled))
                .onHover { hover = $0 }
        }
    }
}

/// Slider in the same style as the buttons: a sharp well with a filled gradient and a square glossy thumb.
struct VistaSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @State private var hover = false
    @ObservedObject private var theme = ButtonTheme.shared
    @Environment(\.vistaTint) private var tint

    init(value: Binding<Double>, in range: ClosedRange<Double>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.range = range; self.onEditingChanged = onEditingChanged
    }

    var body: some View {
        GeometryReader { geo in
            let thumbW: CGFloat = 11, trackW = max(1, geo.size.width - thumbW)
            let span = max(1e-9, range.upperBound - range.lowerBound)
            let f = CGFloat(min(1, max(0, (value - range.lowerBound) / span)))
            let x = thumbW / 2 + f * trackW
            let base = tint ?? theme.base
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.well).frame(height: 6)
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                Rectangle()
                    .fill(LinearGradient(colors: [Color(nsColor: base.mixed(.white, 0.58)), Color(nsColor: base)], startPoint: .top, endPoint: .bottom))
                    .frame(width: max(0, x), height: 6)
                    .overlay(Rectangle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
                VistaFace(pressed: dragging, hover: hover, border: 1)
                    .frame(width: thumbW, height: 18)
                    .offset(x: x - thumbW / 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditingChanged(true) }
                    let t = min(1, max(0, (g.location.x - thumbW / 2) / trackW))
                    value = range.lowerBound + Double(t) * span
                }
                .onEnded { _ in dragging = false; onEditingChanged(false) })
        }
        .frame(height: 20)
    }
}

extension VistaSlider {
    /// For plugin parameters, which are Floats.
    init(value: Binding<Float>, in range: ClosedRange<Float>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(value: Binding<Double>(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Float($0) }),
                  in: Double(range.lowerBound)...Double(range.upperBound), onEditingChanged: onEditingChanged)
    }
}

/// − / + buttons in the button style, replacing the system stepper.
struct VistaStepper<Label: View>: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    @ViewBuilder var label: () -> Label
    var body: some View {
        HStack(spacing: 6) {
            label()
            HStack(spacing: 1) {
                IconButton(symbol: "minus", size: 20, fontSize: 9) { value = max(range.lowerBound, value - step) }
                IconButton(symbol: "plus", size: 20, fontSize: 9) { value = min(range.upperBound, value + step) }
            }
        }
    }
}

struct VistaCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    if configuration.isOn { VistaFace(state: true, border: 1) }
                    else { Rectangle().fill(Theme.well).overlay(Rectangle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1)) }
                    if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) }
                }
                .frame(width: 14, height: 14)
                configuration.label
            }
        }.buttonStyle(.plain)
    }
}

/// A square colour swatch with the glossy frame (track colours).
struct VistaSwatch: View {
    let color: NSColor
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VistaFace(base: color, border: selected ? 2 : 1).frame(width: 18, height: 18)
        }.buttonStyle(.plain)
    }
}

/// Square icon button used across the UI. Leave `active` out for a plain push button; pass it for a toggle.
struct IconButton: View {
    let symbol: String
    var active: Bool? = nil
    var tint: Color? = nil
    var help = ""
    var size: CGFloat = 28
    var fontSize: CGFloat = 13
    let action: () -> Void
    @State private var hover = false
    @State private var down = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(active == false && !hover ? 0.8 : 1))
                .frame(width: size, height: size)
                .background(VistaFace(state: active, base: active == true ? tint.map { NSColor($0) } : nil, pressed: down, hover: hover, border: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in down = true }.onEnded { _ in down = false })
        .help(help)
    }
}

struct SmallTag: View {
    let text: String
    var active = false
    var color: Color = Theme.accent
    var body: some View {
        Text(text)
            .font(Theme.vista(10.5))
            .foregroundStyle(.white.opacity(active ? 1 : 0.8))
            .frame(width: 22, height: 20)
            .background(VistaFace(state: active, base: NSColor(color), border: 0.75))      // off: a dim version of the colour; on: vivid and glowing
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.label).tracking(0.8).foregroundStyle(Theme.faint)
    }
}

#if os(macOS)
/// Makes the hosting window look like the rest of the app and tags it for key handling.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.identifier = NSUserInterfaceItemIdentifier("main")
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false
            w.backgroundColor = Theme.ns.window
            w.minSize = NSSize(width: 980, height: 620)
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
#endif
