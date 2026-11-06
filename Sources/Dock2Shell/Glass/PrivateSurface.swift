import AppKit
import QuartzCore

/// A class or `CAFilter` type of Core Animation's private API. Every one the glass and the mirrors use is a case
/// here, its keys a `PrivateKey`, so what `PrivateAudit` checks is what the code uses: there is no list to keep.
enum PrivateType: String, CaseIterable {
    case layer = "CALayer"
    case backdropLayer = "CABackdropLayer"
    case portalLayer = "CAPortalLayer"
    case sdfLayer = "CASDFLayer"
    case sdfElementLayer = "CASDFElementLayer"
    case sdfOutputEffect = "CASDFOutputEffect"
    case sdfShadowEffect = "CASDFShadowEffect"
    case sdfHighlightEffect = "CASDFKeyFillHighlightEffect"
    case glassBackground, vibrantColorMatrix, displacementMap

    /// The keys dock2 writes on it.
    var keys: [String] {
        switch self {
        case .layer: LayerKey.names
        case .backdropLayer: BackdropKey.names
        case .portalLayer: PortalKey.names
        case .sdfLayer: SDFLayerKey.names
        case .sdfElementLayer, .sdfOutputEffect: []
        case .sdfShadowEffect: ShadowKey.names
        case .sdfHighlightEffect: HighlightKey.names
        case .glassBackground: GlassInput.names
        case .vibrantColorMatrix: VibrancyInput.names
        case .displacementMap: DisplacementInput.names
        }
    }

    private static let filterClass = NSClassFromString("CAFilter") as? NSObject.Type
    private static let filterTypes = filterClass?.perform(NSSelectorFromString("filterTypes"))?.takeUnretainedValue() as? [String] ?? []

    private var isFilter: Bool { [.glassBackground, .vibrantColorMatrix, .displacementMap].contains(self) }

    var exists: Bool {
        isFilter ? Self.filterTypes.contains(rawValue) : NSClassFromString(rawValue) != nil
    }

    /// A new instance, or, for a filter, one named for its type, which is how a key path reaches it.
    func make() -> NSObject {
        guard let filterClass = isFilter ? Self.filterClass : nil else {
            return (NSClassFromString(rawValue) as! NSObject.Type).init()
        }
        return filterClass.perform(NSSelectorFromString("filterWithType:"), with: rawValue)!.takeUnretainedValue() as! NSObject
    }

    /// Those of its `keys` this macOS has, as a filter lists its inputs or a class answers to a setter. Writing one
    /// can't tell: a layer or a filter takes any key at all, and does nothing with one it doesn't know.
    var present: Set<String> {
        guard exists else { return [] }
        if isFilter {
            let inputs = make().perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String]
            return Set(keys).intersection(inputs ?? [])
        }
        let type: AnyClass = NSClassFromString(rawValue)!
        return Set(keys.filter { type.instancesRespond(to: Self.setter($0)) })
    }

    private static func setter(_ key: String) -> Selector {
        NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")
    }
}

/// The keys dock2 writes on one `PrivateType`, each case named for its key. A write can only name a case.
protocol PrivateKey: RawRepresentable<String>, CaseIterable {
    /// What an instance is used as.
    associatedtype Object: NSObject = NSObject
    static var owner: PrivateType { get }
}

extension PrivateKey {
    static var names: [String] { allCases.map(\.rawValue) }

    var isPresent: Bool { Self.owner.present.contains(rawValue) }
}

/// An instance of a private type, written only by its own keys. A key this macOS lacks goes unwritten: a `CASDFEffect`
/// throws on one it doesn't know.
struct Private<Key: PrivateKey> {
    let object: Key.Object
    private let present: Set<String>

    init() {
        self.init(Key.owner.make() as! Key.Object)
    }

    init(_ object: Key.Object) {
        self.object = object
        present = Key.owner.present
    }

    func set(_ key: Key, _ value: Any?) {
        guard present.contains(key.rawValue) else { return }
        object.setValue(value, forKey: key.rawValue)
    }
}

enum LayerKey: String, PrivateKey {
    typealias Object = CALayer
    static let owner = PrivateType.layer

    case allowsGroupBlending
}

enum BackdropKey: String, PrivateKey {
    typealias Object = CALayer
    static let owner = PrivateType.backdropLayer

    case windowServerAware, groupName, scale, marginWidth, sourceSublayerDefinesBounds
}

enum PortalKey: String, PrivateKey {
    typealias Object = CALayer
    static let owner = PrivateType.portalLayer

    case sourceLayer
}

enum SDFLayerKey: String, PrivateKey {
    typealias Object = CALayer
    static let owner = PrivateType.sdfLayer

    case effect, smoothness, mergeElements
}

enum ShadowKey: String, PrivateKey {
    static let owner = PrivateType.sdfShadowEffect

    case color, radius, invert, punchout, offset
}

enum HighlightKey: String, PrivateKey {
    static let owner = PrivateType.sdfHighlightEffect

    case keyColor, keyAngle, keyHeight, keyAmount, keySpread
    case fillColor, fillAngle, fillHeight, fillAmount, fillSpread
    case curvature
    case diffuseHeightScale, diffuseAmountScale, diffuseSpreadScale
}

/// `glassBackground`'s inputs, which `GlassRecipe` is keyed by.
enum GlassInput: String, PrivateKey {
    static let owner = PrivateType.glassBackground

    case inputSourceSublayerName
    case inputInnerRefractionAmount, inputInnerRefractionHeight, inputOuterRefractionAmount, inputOuterRefractionHeight
    case inputRefractionDistance0, inputRefractionDistance1, inputRefractionOpacity
    case inputBlurRadius, inputBlurOpacity0, inputBlurOpacity1, inputBlurOpacity2, inputBlurOpacity3
    case inputBlurDistance0, inputBlurDistance1, inputBlurDistance2, inputBlurDistance3
    case inputBlurFillBlurRadius, inputBlurFillLightenOpacity, inputBlurFillDarkenOpacity, inputBlurFillNormalOpacity
    case inputFaceOpacity, inputFaceColorMatrixWhite, inputFaceColorMatrixBlack, inputFaceColorMatrixSaturation
    case inputFaceColorMatrixFillColor, inputFaceColorMatrixMaxLuma, inputFaceColorMatrixMaxLumaSDR
    case inputBleedAmount, inputBleedHeight, inputBleedOpacity
    case inputShadowAmount, inputShadowHeight, inputShadowOpacity
    case inputRingShadowOffset, inputRingShadowStrokeWidth, inputRingShadowBlurRadius, inputRingShadowOpacity, inputRingShadowMask
    case inputKeyFillHighlightHeight, inputKeyFillHighlightAngle, inputKeyFillHighlightSpread, inputKeyFillHighlightSpreadSDR
    case inputKeyFillHighlightAmount, inputKeyFillHighlightEffectOffset, inputKeyFillHighlightColorBias
    case inputSDRShadowOpacity, inputMaxHeadroom, inputClamp
}

enum VibrancyInput: String, PrivateKey {
    static let owner = PrivateType.vibrantColorMatrix

    case inputColorMatrix, inputClamp
}

enum DisplacementInput: String, PrivateKey {
    static let owner = PrivateType.displacementMap

    case inputMaskImage, inputAmount
}

/// What this macOS lacks of everything `PrivateType` names: a type by its name, a key as `type.key`.
public enum PrivateAudit {
    public static var names: Int {
        PrivateType.allCases.reduce(0) { $0 + 1 + $1.keys.count }
    }

    public static var missing: [String] {
        PrivateType.allCases.flatMap { type -> [String] in
            guard type.exists else { return [type.rawValue] }
            let present = type.present
            return type.keys.filter { !present.contains($0) }.map { "\(type.rawValue).\($0)" }
        }
    }
}
