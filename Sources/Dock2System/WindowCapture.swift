import AppKit
import ApplicationServices

/// Pictures of other apps' windows, minimised ones included, which ScreenCaptureKit will not take: SkyLight's
/// window capture, and HIServices' number for an Accessibility window (both private). Neither is reached
/// without Screen Recording.
public enum WindowCapture {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CaptureList = @convention(c) (Int32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?

    nonisolated(unsafe) private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    nonisolated(unsafe) private static let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
    private static let getWindow = hiServices.flatMap { dlsym($0, "_AXUIElementGetWindow") }.map { unsafeBitCast($0, to: GetWindow.self) }
    private static let mainConnection = skyLight.flatMap { dlsym($0, "SLSMainConnectionID") }.map { unsafeBitCast($0, to: MainConnection.self) }
    private static let captureList = skyLight.flatMap { dlsym($0, "SLSHWCaptureWindowList") }.map { unsafeBitCast($0, to: CaptureList.self) }
    /// The window's own shape, at the display's resolution.
    private static let captureOptions: UInt32 = 1 << 11 | 1 << 8

    /// Whether macOS lets dock2 record the screen. Asking this asks nobody.
    public static var isAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// The system's request for Screen Recording, once.
    public static func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
    }

    /// The window server's number for a window Accessibility gives, which outlasts the window's minimising.
    public static func number(of window: AXUIElement) -> CGWindowID? {
        var number: CGWindowID = 0
        guard let getWindow, getWindow(window, &number) == .success, number != 0 else { return nil }
        return number
    }

    /// The window as it is now, no more than `maxPixels` on its longer side: nil without Screen Recording, or
    /// on a macOS without the capture.
    public static func picture(of window: CGWindowID, maxPixels: Int) -> CGImage? {
        guard isAllowed, let mainConnection, let captureList else { return nil }
        var number = window
        guard let images = captureList(mainConnection(), &number, 1, captureOptions)?.takeRetainedValue() as? [CGImage],
              let image = images.first, image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, Double(maxPixels) / Double(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        let space = image.colorSpace?.model == .rgb ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
