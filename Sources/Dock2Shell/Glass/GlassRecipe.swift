import CoreGraphics
import Foundation

/// The numbers behind one glass: the `glassBackground` filter's inputs, how smoothly its shapes merge,
/// and the rims over it. The platter's were fitted against the real Dock; the label's are AppKit's own.
struct GlassRecipe {
    /// Keyed by the filter's input names. Inputs not named keep the filter's defaults.
    var filter: [String: Any]
    /// How far apart shapes start to melt into each other, in points.
    var smoothness: Double
    var rims: [Rim]

    /// A light — or, in black, a shade — along the edge, strongest where the edge faces `keyAngle` or
    /// `fillAngle`. Angles are in the layer's flipped space: 0 is down, π/2 right, π up.
    struct Rim {
        var outset: Double = 0
        var color: CGColor = CGColor(gray: 1, alpha: 1)
        var keyAngle: Double = .pi
        var fillAngle: Double = 0
        var height: Double
        var keyAmount: Double
        var fillAmount: Double
        var spread: Double
    }

    // MARK: - The Dock's platter

    static func platter(dark: Bool) -> GlassRecipe {
        var filter = platterBase
        // Fitted in light mode. Dark mode applies the change AppKit's dock-family recipe makes between
        // its own light and dark versions (white 0.95 → 0.8, black 0.2 → 0.05), not a measurement.
        filter["inputFaceColorMatrixWhite"] = dark ? 0.75 : 0.8925
        filter["inputFaceColorMatrixBlack"] = dark ? 0.04 : 0.15
        return GlassRecipe(filter: filter, smoothness: 8, rims: rims)
    }

    nonisolated(unsafe) private static let platterBase: [String: Any] = [
        "inputInnerRefractionAmount": -45, "inputInnerRefractionHeight": 11.5,
        "inputOuterRefractionAmount": 0, "inputOuterRefractionHeight": 0,
        "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0,
        "inputBlurRadius": 0.85, "inputBlurOpacity0": 1, "inputBlurOpacity1": 1, "inputBlurOpacity2": 1, "inputBlurOpacity3": 1,
        "inputFaceOpacity": 1, "inputFaceColorMatrixSaturation": 1.3, "inputFaceColorMatrixFillColor": color(1, 1, 1, 0),
        "inputFaceColorMatrixMaxLuma": 1, "inputFaceColorMatrixMaxLumaSDR": 1,
        "inputKeyFillHighlightHeight": 0.5, "inputKeyFillHighlightAngle": Double.pi / 2,
        "inputKeyFillHighlightSpread": 1.308997, "inputKeyFillHighlightSpreadSDR": 1.308997,
        "inputKeyFillHighlightAmount": 0.4, "inputKeyFillHighlightEffectOffset": -0.5, "inputKeyFillHighlightColorBias": -0.25,
        "inputClamp": 1, "inputMaxHeadroom": 9999,
        "inputBlurFillBlurRadius": 0, "inputBlurFillLightenOpacity": 0, "inputBlurFillDarkenOpacity": 0, "inputBlurFillNormalOpacity": 0,
        "inputBleedAmount": 0, "inputBleedHeight": 0, "inputBleedOpacity": 0,
        "inputShadowAmount": 0, "inputShadowHeight": 0, "inputShadowOpacity": 0, "inputRingShadowOpacity": 0, "inputSDRShadowOpacity": 0,
    ]

    /// A soft light along the top and bottom, a sharp line on the very edge of both, and a hairline of
    /// shade just outside the two ends.
    private static let rims: [Rim] = [
        Rim(height: 3.2, keyAmount: 0.075, fillAmount: 0.08, spread: 1.6),
        Rim(height: 0.2, keyAmount: 0.3, fillAmount: 0.3, spread: 0.9),
        Rim(outset: 0.5, color: CGColor(gray: 0, alpha: 1), keyAngle: .pi / 2, fillAngle: 3 * .pi / 2,
            height: 0.5, keyAmount: 0.6, fillAmount: 0.6, spread: 1.6),
    ]

    // MARK: - The name label

    static func label(dark: Bool) -> GlassRecipe {
        GlassRecipe(filter: dark ? regularDark : regularLight, smoothness: 12, rims: Array(rims.prefix(2)))
    }

    /// AppKit's regular glass in the light appearance, as `NSGlassEffectView` configures it.
    nonisolated(unsafe) private static let regularLight: [String: Any] = regularShared.merging([
        "inputFaceColorMatrixWhite": 0.96, "inputFaceColorMatrixBlack": 0.4, "inputFaceColorMatrixSaturation": 1.2,
        "inputFaceColorMatrixFillColor": color(1, 1, 1, 0.2), "inputFaceColorMatrixMaxLuma": 1, "inputFaceColorMatrixMaxLumaSDR": 0.94,
        "inputBleedDarkenBlend": 1, "inputBleedColorMatrixWhite": 1, "inputBleedColorMatrixBlack": 0.9, "inputBleedColorMatrixSaturation": 1.2,
        "inputBlurFillLightenOpacity": 0.9, "inputBlurFillDarkenOpacity": 0,
    ]) { $1 }

    /// The same in the dark appearance.
    nonisolated(unsafe) private static let regularDark: [String: Any] = regularShared.merging([
        "inputFaceColorMatrixWhite": 1.125, "inputFaceColorMatrixBlack": 0.08, "inputFaceColorMatrixSaturation": 1.3,
        "inputFaceColorMatrixFillColor": color(0, 0, 0, 0), "inputFaceColorMatrixMaxLuma": 0.35, "inputFaceColorMatrixMaxLumaSDR": 0.35,
        "inputBleedDarkenBlend": 0, "inputBleedColorMatrixWhite": 0.5, "inputBleedColorMatrixBlack": 0.125, "inputBleedColorMatrixSaturation": 1,
        "inputBlurFillLightenOpacity": 0, "inputBlurFillDarkenOpacity": 0.9,
    ]) { $1 }

    nonisolated(unsafe) private static let regularShared: [String: Any] = [
        "inputBackdropAware": 1,
        "inputInnerRefractionAmount": -57.5, "inputInnerRefractionHeight": 20,
        "inputOuterRefractionAmount": 0, "inputOuterRefractionHeight": 0,
        "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0,
        "inputBlurRadius": 5, "inputBlurOpacity0": 0.6125, "inputBlurOpacity1": 0.6125, "inputBlurOpacity2": 1, "inputBlurOpacity3": 1,
        "inputBlurDistance0": 0, "inputBlurDistance1": 0, "inputBlurDistance2": 0, "inputBlurDistance3": 0,
        "inputFaceOpacity": 1,
        "inputBleedAmount": 40.25, "inputBleedHeight": 40.25, "inputBleedBlurRadius": 0,
        "inputBleedDistance0": 1, "inputBleedDistance1": 0, "inputBleedOpacity": 0,
        "inputShadowOffset": NSValue(size: CGSize(width: 0, height: 8)),
        "inputShadowAmount": 0, "inputShadowHeight": 0, "inputShadowOpacity": 0,
        "inputShadowColorMatrixWhite": 1, "inputShadowColorMatrixBlack": 0, "inputShadowColorMatrixSaturation": 1,
        "inputShadowColorMatrixFillColor": color(0, 0, 0, 0.3),
        "inputShadowDistanceOffset": 0, "inputShadowBlurRadius": 0, "inputShadowRadius": 0,
        "inputRingShadowOffset": 8, "inputRingShadowStrokeWidth": 4, "inputRingShadowBlurRadius": 5,
        "inputRingShadowOpacity": 0, "inputRingShadowMask": 1,
        "inputKeyFillHighlightHeight": 0.5, "inputKeyFillHighlightAngle": Double.pi / 2,
        "inputKeyFillHighlightSpread": 2.094395, "inputKeyFillHighlightSpreadSDR": 2.094395,
        "inputKeyFillHighlightAmount": 0.5, "inputKeyFillHighlightEffectOffset": -0.5, "inputKeyFillHighlightColorBias": -0.1875,
        "inputBlurFillBlurRadius": 8, "inputBlurFillNormalOpacity": 0.5,
        "inputSDRHoldingToneEnabled": 0, "inputSDRHoldingToneWhite": 1,
        "inputSDRGradientDistance0": 1, "inputSDRGradientDistance1": 1, "inputSDRShadowOpacity": 0,
        "inputMaxHeadroom": 9999, "inputShadowVibrancyContribution": 0, "inputClamp": 1, "inputClampPreserveHue": 0,
    ]

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
