import SwiftUI
import AVFoundation

#if os(macOS)
/// The instrument that plays sampled sounds: Apple's sampler on the Mac (the iOS version is in iOS/Sources/SF2Synth.swift).
typealias SamplerUnit = AVAudioUnitSampler
#endif

// Lets the code that was written for the Mac (colours, fonts and Core Graphics drawing named after AppKit) compile on iOS too.
// On the Mac this file adds nothing.
#if canImport(UIKit)
import UIKit

typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSPoint = CGPoint
typealias NSRect = CGRect
typealias NSSize = CGSize

enum ShimColorSpace { case sRGB, deviceRGB, genericRGB }

/// The colour buttons and highlights use when there is no system accent colour to follow (iOS has none).
enum AppAccent {
    static let coral = UIColor(red: 1.0, green: 0.32, blue: 0.34, alpha: 1)
}

extension UIColor {
    convenience init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) { self.init(red: r, green: g, blue: b, alpha: a) }
    static var controlAccentColor: UIColor { AppAccent.coral }
    static let systemColorsDidChangeNotification = Notification.Name("MacBandShim.systemColorsDidChange")

    func usingColorSpace(_ space: ShimColorSpace) -> UIColor? { self }

    private var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getRed(&r, green: &g, blue: &b, alpha: &a) { return (r, g, b, a) }
        var w: CGFloat = 0
        if getWhite(&w, alpha: &a) { return (w, w, w, a) }
        return (0, 0, 0, 1)
    }
    var redComponent: CGFloat { rgba.0 }
    var greenComponent: CGFloat { rgba.1 }
    var blueComponent: CGFloat { rgba.2 }
    var alphaComponent: CGFloat { rgba.3 }
    var hueComponent: CGFloat { var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; getHue(&h, saturation: &s, brightness: &b, alpha: &a); return h }
    var saturationComponent: CGFloat { var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; getHue(&h, saturation: &s, brightness: &b, alpha: &a); return s }
    var brightnessComponent: CGFloat { var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; getHue(&h, saturation: &s, brightness: &b, alpha: &a); return b }

    func blended(withFraction f: CGFloat, of other: UIColor) -> UIColor? {
        let a = rgba, b = other.rgba
        return UIColor(red: a.0 + (b.0 - a.0) * f, green: a.1 + (b.1 - a.1) * f, blue: a.2 + (b.2 - a.2) * f, alpha: a.3 + (b.3 - a.3) * f)
    }
}

extension Color {
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}

/// `NSGraphicsContext` for the drawing code: the context UIKit is drawing into, and a way to make another one current while text is drawn.
final class NSGraphicsContext {
    let cgContext: CGContext
    let isFlipped: Bool
    init(cgContext: CGContext, flipped: Bool) { self.cgContext = cgContext; isFlipped = flipped }
    private static var pushed = 0
    static var current: NSGraphicsContext? {
        get { UIGraphicsGetCurrentContext().map { NSGraphicsContext(cgContext: $0, flipped: true) } }
        set { if let c = newValue { UIGraphicsPushContext(c.cgContext); pushed += 1 } }
    }
    static func saveGraphicsState() {}
    static func restoreGraphicsState() { if pushed > 0 { UIGraphicsPopContext(); pushed -= 1 } }
}

extension NSString {
    // UIKit has draw(at:withAttributes:) and size(withAttributes:) on NSString already.
}
#endif
