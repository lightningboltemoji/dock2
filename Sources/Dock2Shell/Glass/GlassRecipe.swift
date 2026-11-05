import CoreGraphics
import Dock2Core
import Foundation

/// The numbers behind one glass: the `glassBackground` filter's inputs, how smoothly its shapes merge,
/// and the rims over it. The Dock's glasses were fitted against the real Dock, in each appearance; the pane starts
/// from what AppKit gives a search field.
struct GlassRecipe {
    /// Keyed by the filter's input names. Inputs not named keep the filter's defaults.
    var filter: [String: Any]
    /// How far apart shapes start to melt into each other, in points.
    var smoothness: Double
    var rims: [Rim]
    /// The filter's inputs as a lens (`GlassLayer.lens`): clearer and bending more, to see a gem through.
    var lens: [String: Any] = [:]
    /// The backdrop's sampling resolution: the system's half, or whole for what must read sharp beneath it.
    var scale = 0.5
    /// Whether it has a face — the backdrop the filter runs over — or only its rims, drawn over what lies beneath.
    var hasFace = true
    /// How far past its shapes the backdrop draws, in points: without it, the glass casts nothing on what lies beneath.
    var margin = 0.0
    /// The shadow its edge throws on what lies beneath, under the rims.
    var cast: Cast?

    /// A shadow in `color`, softened over `radius` and let `drop` down the screen: past the shapes' feet or, `inward`, as
    /// a hole's, inside their top edges.
    struct Cast {
        var color: CGColor
        var radius: Double
        var drop: Double
        var inward = false
    }

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
        /// How gently the light tapers where the edge turns a corner, and, below the effect's default of 1, how far it
        /// saturates along a straight edge.
        var curvature = 1.0
        /// The soft light falling inward from the line, without which the edge has no thickness.
        var halo: Halo?
        /// Drawn through the system's vibrancy, which holds white back to a lift of what lies beneath.
        var isVibrant = false
    }

    /// A rim's soft light, each a multiple of the line's own height, amount and spread.
    struct Halo {
        var height: Double
        var amount: Double
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

    /// The field: Spotlight's clear glass — the label's, less saturated, with a sharp light along the top and
    /// bottom edges.
    static func panel(dark: Bool, lens: Bool = false) -> GlassRecipe {
        var recipe = label(dark: dark)
        if lens {
            // The gem's marble, clear enough to see its facets through and to leave an emerald's darks dark.
            recipe.lens = ["inputBlurRadius": 0.35, "inputInnerRefractionAmount": -28, "inputInnerRefractionHeight": 14,
                           "inputFaceColorMatrixBlack": 0.06, "inputFaceColorMatrixWhite": 0.96,
                           "inputFaceColorMatrixMaxLuma": 0.92, "inputFaceColorMatrixMaxLumaSDR": 0.92]
            recipe.scale = 1
        }
        guard !dark else { return recipe }
        recipe.filter["inputFaceColorMatrixSaturation"] = 1.0612
        recipe.rims.append(Rim(height: 0.5, keyAmount: 0.45, fillAmount: 0.45, spread: 0.9))
        return recipe
    }

    /// The glass laid over the panel's ground (`PanelGround`) once it grows, and over a toast's: the system's own for a
    /// control, as AppKit builds a sidebar's search field, its dark face lowered for a pane far larger than a field. It
    /// reads by its edge: the face stays under white to leave the rim room, and the rim and shadows give it its thickness.
    static func pane(dark: Bool) -> GlassRecipe {
        var filter = controlBase
        filter["inputFaceColorMatrixBlack"] = dark ? 0.07 : 0.4
        filter["inputFaceColorMatrixWhite"] = dark ? 1.125 : 1.03
        filter["inputFaceColorMatrixSaturation"] = dark ? 1.3 : 1.2
        filter["inputFaceColorMatrixFillColor"] = dark ? color(0, 0, 0, 0) : color(1, 1, 1, 0.2)
        filter["inputFaceColorMatrixMaxLuma"] = dark ? 0.6 : 1
        filter["inputFaceColorMatrixMaxLumaSDR"] = dark ? 0.6 : 0.94
        filter["inputClamp"] = dark ? 1.308311 : 1.06961
        filter["inputKeyFillHighlightSpread"] = dark ? 1.308997 : 1.675516
        filter["inputKeyFillHighlightSpreadSDR"] = dark ? 1.308997 : 1.850049
        var recipe = GlassRecipe(filter: filter, smoothness: 0, rims: [
            Rim(keyAngle: 0, fillAngle: .pi, height: 1, keyAmount: 0.7, fillAmount: 0.7, spread: 1.396263, curvature: 0.75,
                halo: Halo(height: 8, amount: 0.15, spread: 0.65), isVibrant: true),
        ])
        recipe.cast = paneCast(dark: dark)
        // No further than the ground's rim, or it samples the desktop past the ground's edge.
        recipe.margin = PanelMetrics.paneInset
        return recipe
    }

    /// The control glass's inputs shared by both appearances. Its ring shadow falls down the screen: the system's tree
    /// is flipped and this one is not, so its offset is the system's negated. Its blur fill and cast are off: the margin
    /// that keeps the fill from reaching past the ground's rim would clip the cast (`paneCast`).
    nonisolated(unsafe) private static let controlBase: [String: Any] = [
        "inputInnerRefractionAmount": -14, "inputInnerRefractionHeight": 7,
        "inputOuterRefractionAmount": 16, "inputOuterRefractionHeight": 16,
        "inputRefractionDistance0": -1, "inputRefractionDistance1": 0, "inputRefractionOpacity": 0.6,
        "inputBlurRadius": 5, "inputBlurOpacity0": 0, "inputBlurOpacity1": 0, "inputBlurOpacity2": 0.5, "inputBlurOpacity3": 1,
        "inputBlurDistance0": -14, "inputBlurDistance1": -1, "inputBlurDistance2": 0, "inputBlurDistance3": 0,
        "inputBlurFillBlurRadius": 0, "inputBlurFillLightenOpacity": 0, "inputBlurFillDarkenOpacity": 0, "inputBlurFillNormalOpacity": 0,
        "inputFaceOpacity": 1,
        "inputKeyFillHighlightHeight": 0.5, "inputKeyFillHighlightAngle": Double.pi / 2,
        "inputKeyFillHighlightAmount": 0.4, "inputKeyFillHighlightEffectOffset": -0.5, "inputKeyFillHighlightColorBias": -0.25,
        "inputMaxHeadroom": 1.2,
        "inputBleedOpacity": 0,
        "inputRingShadowOpacity": 0.06, "inputRingShadowOffset": -8, "inputRingShadowStrokeWidth": 4,
        "inputRingShadowBlurRadius": 5, "inputRingShadowMask": 1,
        "inputShadowOpacity": 0,
    ]

    /// What the pane's thickness throws on the ground, past its foot and into a selection alike: one edge over one
    /// ground, so the cut goes exactly as deep as the pane stands high.
    private static func paneCast(dark: Bool, inward: Bool = false) -> Cast {
        Cast(color: CGColor(gray: 0, alpha: dark ? 0.2 : 0.085), radius: 3, drop: 3, inward: inward)
    }

    /// A selection let down through the pane to its ground (`GroundInset`): the pane's edge seen from the other side,
    /// with no face. The glass above throws its shadow in, and the glass below catches the light on its edge.
    static func inset(dark: Bool) -> GlassRecipe {
        var recipe = GlassRecipe(filter: [:], smoothness: 0, rims: [
            Rim(keyAngle: 0, fillAngle: .pi, height: 1, keyAmount: dark ? 0.2 : 0.7, fillAmount: 0.005, spread: 1.6, curvature: 2),
        ])
        recipe.cast = paneCast(dark: dark, inward: true)
        recipe.hasFace = false
        return recipe
    }

    private static func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
