import CoreGraphics
import QuartzCore
import SwiftUI
import UIKit

/// A simple RGBA color that's Codable and easy to bridge to both SwiftUI's
/// `Color` (for controls) and `CGColor` (for the CALayer-based renderer).
struct RGBAColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var cgColor: CGColor {
        CGColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    /// For feeding a PencilKit `PKInkingTool` directly, rather than
    /// bridging through SwiftUI's `Color` (which can resolve slightly
    /// differently depending on color-scheme/appearance).
    var uiColor: UIColor {
        UIColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)

    /// Swatches for the pen color picker in the "Draw" section.
    static let drawPresets: [RGBAColor] = [
        .white,
        .black,
        RGBAColor(red: 1.00, green: 0.23, blue: 0.19),
        RGBAColor(red: 1.00, green: 0.58, blue: 0.00),
        RGBAColor(red: 1.00, green: 0.80, blue: 0.00),
        RGBAColor(red: 0.20, green: 0.78, blue: 0.35),
        RGBAColor(red: 0.00, green: 0.48, blue: 1.00)
    ]
}

/// What sits behind the video on the canvas. `.none` still renders an
/// opaque black backdrop under the hood (a standard MP4 has no transparency
/// channel), but skips any color/gradient treatment — matches picking
/// "None" in the UI.
enum BackgroundStyle: Codable, Equatable, Hashable {
    case solid(RGBAColor)
    case gradient(RGBAColor, RGBAColor)
    case none

    /// Builds the CALayer to place behind the video content in the render
    /// tree (see VideoComposer).
    func makeLayer(size: CGSize) -> CALayer {
        switch self {
        case .solid(let color):
            let layer = CALayer()
            layer.frame = CGRect(origin: .zero, size: size)
            layer.backgroundColor = color.cgColor
            return layer
        case .gradient(let start, let end):
            let layer = CAGradientLayer()
            layer.frame = CGRect(origin: .zero, size: size)
            layer.colors = [start.cgColor, end.cgColor]
            layer.startPoint = CGPoint(x: 0, y: 0)
            layer.endPoint = CGPoint(x: 1, y: 1)
            return layer
        case .none:
            let layer = CALayer()
            layer.frame = CGRect(origin: .zero, size: size)
            layer.backgroundColor = RGBAColor.black.cgColor
            return layer
        }
    }

    /// Swatches for the "Color" tab in BackgroundControlsView.
    static let colorPresets: [BackgroundStyle] = [
        .solid(.black),
        .solid(.white),
        .solid(RGBAColor(red: 0.14, green: 0.14, blue: 0.16)),
        .solid(RGBAColor(red: 0.85, green: 0.20, blue: 0.20)),
        .solid(RGBAColor(red: 0.20, green: 0.45, blue: 0.85)),
        .solid(RGBAColor(red: 0.20, green: 0.55, blue: 0.35))
    ]

    /// Swatches for the "Gradient" tab in BackgroundControlsView.
    static let gradientPresets: [BackgroundStyle] = [
        .gradient(RGBAColor(red: 0.09, green: 0.10, blue: 0.14), RGBAColor(red: 0.25, green: 0.27, blue: 0.36)),
        .gradient(RGBAColor(red: 0.98, green: 0.42, blue: 0.42), RGBAColor(red: 0.98, green: 0.74, blue: 0.28)),
        .gradient(RGBAColor(red: 0.25, green: 0.55, blue: 0.95), RGBAColor(red: 0.55, green: 0.85, blue: 0.98)),
        .gradient(RGBAColor(red: 0.42, green: 0.86, blue: 0.65), RGBAColor(red: 0.20, green: 0.55, blue: 0.45))
    ]
}
