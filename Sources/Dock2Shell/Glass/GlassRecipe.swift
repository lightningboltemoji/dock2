import CoreGraphics
import Foundation

/// The numbers behind one glass: the `glassBackground` filter's inputs, how smoothly its shapes merge,
/// and the rims over it. Both glasses were fitted against the real Dock, in each appearance.
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
        filter["inputFaceColorMatrixWhite"] = dark ? 0.7812 : 0.8925
        filter["inputFaceColorMatrixBlack"] = dark ? 0.06 : 0.15
        filter["inputFaceColorMatrixSaturation"] = dark ? 1.2 : 1.3
        // Dark mode holds highlights down: white behind the glass comes out at 175 of 255.
        filter["inputFaceColorMatrixMaxLuma"] = dark ? 0.8875 : 1
        filter["inputFaceColorMatrixMaxLumaSDR"] = dark ? 0.8875 : 1
        return GlassRecipe(filter: filter, smoothness: 8, rims: dark ? darkRims : rims)
    }

    nonisolated(unsafe) private static let platterBase: [String: Any] = [
        "inputInnerRefractionAmount": -45, "inputInnerRefractionHeight": 11.5,
        "inputOuterRefractionAmount": 0, "inputOuterRefractionHeight": 0,
        "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0,
        "inputBlurRadius": 0.85, "inputBlurOpacity0": 1, "inputBlurOpacity1": 1, "inputBlurOpacity2": 1, "inputBlurOpacity3": 1,
        "inputFaceOpacity": 1, "inputFaceColorMatrixFillColor": color(1, 1, 1, 0),
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
    private static let rims = platterRims(soft: 0.075, softBottom: 0.08)

    /// The same, the soft light dimmer: over the darker glass the same light would read brighter.
    private static let darkRims = platterRims(soft: 0.055, softBottom: 0.055)

    private static func platterRims(soft: Double, softBottom: Double) -> [Rim] {
        [
            Rim(height: 3.2, keyAmount: soft, fillAmount: softBottom, spread: 1.6),
            Rim(height: 0.2, keyAmount: 0.3, fillAmount: 0.3, spread: 0.9),
            Rim(outset: 0.5, color: CGColor(gray: 0, alpha: 1), keyAngle: .pi / 2, fillAngle: 3 * .pi / 2,
                height: 0.5, keyAmount: 0.6, fillAmount: 0.6, spread: 1.6),
        ]
    }

    // MARK: - The name label

    /// The platter's kind of glass, blurred more and lightened further, under fainter rims.
    static func label(dark: Bool) -> GlassRecipe {
        var filter = platterBase
        filter["inputBlurRadius"] = dark ? 4.5 : 5.25
        filter["inputInnerRefractionAmount"] = dark ? -0.65 : 3
        filter["inputFaceColorMatrixWhite"] = dark ? 0.91 : 1.18
        filter["inputFaceColorMatrixBlack"] = dark ? 0.1675 : 0.5125
        filter["inputFaceColorMatrixSaturation"] = dark ? 1.29 : 1.1812
        filter["inputFaceColorMatrixMaxLuma"] = dark ? 0.7475 : 1
        filter["inputFaceColorMatrixMaxLumaSDR"] = dark ? 0.7475 : 0.7875
        let rims = dark
            ? [Rim(height: 3.4, keyAmount: 0.0188, fillAmount: 0.0175, spread: 1.6),
               Rim(height: 0.2, keyAmount: 0.05, fillAmount: 0.12, spread: 0.9)]
            : [Rim(height: 3.2, keyAmount: 0.0063, fillAmount: 0.0019, spread: 1.6)]
        return GlassRecipe(filter: filter, smoothness: 12, rims: rims)
    }

    // MARK: - The panel

    /// The field and what grows from it: Spotlight's frosted glass — the label's, less saturated, with a
    /// sharp light along the top and bottom edges. Fitted in the light appearance only.
    static func panel(dark: Bool) -> GlassRecipe {
        var recipe = label(dark: dark)
        guard !dark else { return recipe }
        recipe.filter["inputFaceColorMatrixSaturation"] = 1.0612
        recipe.rims.append(Rim(height: 0.5, keyAmount: 0.45, fillAmount: 0.45, spread: 0.9))
        return recipe
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
