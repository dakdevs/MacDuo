import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

@MainActor
enum DesktopSnapshot {
    static func take(displayID: CGDirectDisplayID) async throws -> CVPixelBuffer {
        try Task.checkCancellation()
        // Access is requested only by the application's explicit permission action.
        guard CGPreflightScreenCaptureAccess() else {
            throw SnapshotError.unavailable("Screen Recording access is required. Enable it in MacDuo's menu.")
        }
        guard CGDisplayIsBuiltin(displayID) != 0 else {
            throw SnapshotError.unavailable("MacDuo can capture only the built-in display.")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let mode = CGDisplayCopyDisplayMode(displayID) else {
            throw SnapshotError.unavailable("The built-in display is unavailable for capture.")
        }
        guard let ownApplication = content.applications.first(where: {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }) else {
            throw SnapshotError.unavailable("MacDuo could not exclude its own windows from the screenshot.")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        let configuration = SCStreamConfiguration()
        configuration.width = mode.pixelWidth
        configuration.height = mode.pixelHeight
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB

        try Task.checkCancellation()
        let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard sample.isValid, CMSampleBufferDataIsReady(sample), let pixels = sample.imageBuffer else {
            throw SnapshotError.unavailable("The screenshot did not contain a valid image.")
        }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pixels) == configuration.width,
              CVPixelBufferGetHeight(pixels) == configuration.height else {
            throw SnapshotError.unavailable("The screenshot returned an unexpected pixel format or size.")
        }
        return pixels
    }

    private enum SnapshotError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case let .unavailable(message): return message }
        }
    }
}
