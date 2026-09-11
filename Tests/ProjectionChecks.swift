import AppKit
import CoreVideo
import MetalKit
import simd

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailure(message: message) }
}

@main
struct ProjectionChecks {
    @MainActor
    static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "work/projection-checks")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try verifyGeometry()
        _ = NSApplication.shared
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let renderer = try PlaneRenderer(view: view)
        try verifyGPU(renderer, output: output)
        try verifyFrost(renderer, output: output)
        try verifyFortyFiveBrightness(renderer, output: output)
        try await verifyPreparation()
        print("PASS: identity, fixed hinge, finite mapping, independent ray-plane oracle, GPU orientation/colors/perspective, reopening, cleared frame, and closure fade.")
        print("Rendered calibration images: \(output.path)")
    }

    private static func verifyGeometry() throws {
        let calibration = ViewCalibration(perspective: 1)
        for degrees: Float in [90, 103, 120, 180] {
            let projection = PlaneProjection(degrees: degrees, calibration: calibration)
            for uv in [SIMD2<Float>(0.13, 0.21), SIMD2<Float>(0.83, 0.77), SIMD2<Float>(0, 0), SIMD2<Float>(1, 1)] {
                guard let actual = projection.sourceUV(uv) else { throw CheckFailure(message: "Upright image was clipped.") }
                try check(simd_distance(actual, uv) < 0.000001, "At or above 90°, the desktop must be unchanged.")
            }
        }
        for degrees in 0...180 {
            let projection = PlaneProjection(degrees: Float(degrees), calibration: calibration)
            try check(projection.visibility.isFinite && (0...1).contains(projection.visibility), "Invalid visibility at \(degrees)°.")
            for x: Float in [0, 0.1, 0.5, 0.9, 1] {
                guard let hinge = projection.sourceUV(SIMD2(x, 1)) else { throw CheckFailure(message: "The hinge disappeared.") }
                try check(simd_distance(hinge, SIMD2(x, 1)) < 0.000001, "The hinge moved at \(degrees)°.")
                for y: Float in [0, 0.1, 0.5, 0.9, 1] {
                    if let uv = projection.sourceUV(SIMD2(x, y)) {
                        try check(uv.x.isFinite && uv.y.isFinite, "A singular mapping escaped at \(degrees)°.")
                    }
                }
            }
        }
        try check(PlaneProjection(degrees: 30, calibration: calibration).visibility == 0,
                  "The plane must dissolve before its approximately 29.5° grazing angle.")
        try check(PlaneProjection(degrees: .nan, calibration: calibration).sourceUV(SIMD2(0.5, 0.5)) == nil,
                  "Nonfinite sensor data must not enter geometry.")

        // Independently worked eye-ray intersections in centimetres at45°,
        // with eye(0,34,60) and physical screen height22.4cm. The top pixel sees
        //58.37% down the upright image; the middle pixel sees82.35% down it.
        let fortyFive = PlaneProjection(degrees: 45, calibration: ViewCalibration())
        let top = fortyFive.sourceUV(SIMD2(0.5, 0))!
        let middle = fortyFive.sourceUV(SIMD2(0.5, 0.5))!
        try check(abs(top.y - 0.5837) < 0.0001 && abs(middle.y - 0.8235) < 0.0001,
                  "Default45° projection does not match the independently worked eye rays.")
        try check(fortyFive.visibility == 1, "The confirmed viewpoint must keep the screen fully lit at45°.")
        let elevated = ViewCalibration(distanceCM: 40, heightCM: 80)
        try check(PlaneProjection(degrees: 65, calibration: elevated).visibility == 0,
                  "Elevated eyes must fade before their own63.43° grazing angle, not an absolute45° threshold.")
        try check(PlaneProjection(degrees: 80, calibration: elevated).visibility == 1,
                  "The elevated viewpoint should remain lit above its adaptive fade range.")

        // Independent oracle: project V toward the eye onto the actual tilted plane.
        // This uses the general vector line/plane intersection, the opposite direction
        // from the production inverse, and catches cosine signs and fake sine shrinking.
        var recoveredTargets = 0
        for calibration in [ViewCalibration(perspective: 1), ViewCalibration(distanceCM: 85, heightCM: 25, screenHeightCM: 22.4, frost: 1, perspective: 1)] {
            let eye = SIMD3<Float>(0, calibration.heightCM / calibration.screenHeightCM,
                                  calibration.distanceCM / calibration.screenHeightCM)
            let aspect: Float = 1.6
            for angle: Float in [40, 50, 60, 75, 90] {
                let radians = angle * .pi / 180
                let tangent = SIMD3<Float>(0, sin(radians), cos(radians))
                let normal = simd_cross(SIMD3<Float>(1, 0, 0), tangent)
                for targetU: Float in [0.2, 0.5, 0.8] {
                    for targetV: Float in [0.35, 0.6, 0.85, 0.98] {
                        let target = SIMD3<Float>((targetU - 0.5) * aspect, 1 - targetV, 0)
                        let direction = target - eye
                        let parameter = -simd_dot(normal, eye) / simd_dot(normal, direction)
                        let point = eye + parameter * direction
                        let panelUV = SIMD2<Float>(0.5 + point.x / aspect, 1 - simd_dot(point, tangent))
                        if panelUV.x < 0 || panelUV.x > 1 || panelUV.y < 0 || panelUV.y > 1 { continue }
                        guard let recovered = PlaneProjection(degrees: angle, calibration: calibration).sourceUV(panelUV) else {
                            throw CheckFailure(message: "A visible virtual target was incorrectly clipped at \(angle)°.")
                        }
                        try check(simd_distance(recovered, SIMD2(targetU, targetV)) < 0.00002,
                                  "The physical and virtual points are not on the same eye ray at \(angle)°.")
                        recoveredTargets += 1
                    }
                }
            }
        }
        try check(recoveredTargets > 70, "The oracle did not exercise enough visible targets.")
        let point = SIMD2<Float>(0.25, 0.375)
        var displacements: [Float] = []
        for strength: Float in [0, 0.25, 0.55, 1] {
            let projection = PlaneProjection(degrees: 60, calibration: ViewCalibration(perspective: strength))
            let result = projection.sourceUV(point)!
            displacements.append(simd_distance(result, point))
        }
        try check(displacements[0] == 0, "Zero perspective must leave texture coordinates unchanged.")
        try check(displacements[1] > 0 && displacements[1] < displacements[2] && displacements[2] < displacements[3],
                  "Perspective strength must progressively increase displacement.")
        try check((0.5...0.6).contains(displacements[2] / displacements[3]),
                  "A55% setting should use approximately half of the full physical correction.")
        for angle: Float in [0, 30, 60, 90, 150] {
            let zero = PlaneProjection(degrees: angle, calibration: ViewCalibration(perspective: 0))
            try check(zero.sourceUV(point) == point, "Zero correction must preserve coordinates at every angle.")
        }
        let edge = SIMD2<Float>(0.07, 0.1)
        try check(PlaneProjection(degrees: 60, calibration: ViewCalibration(perspective: 1)).sourceUV(edge) == nil,
                  "The full correction should clip this point outside the virtual desktop.")
        try check(PlaneProjection(degrees: 60, calibration: ViewCalibration(perspective: 0.55)).sourceUV(edge) != nil,
                  "Clipping before the strength blend discarded a point visible at55% correction.")
        let invalid = PlaneProjection(degrees: 60, calibration: ViewCalibration(perspective: .nan))
        try check(invalid.sourceUV(point) == PlaneProjection(degrees: 60, calibration: ViewCalibration()).sourceUV(point),
                  "Invalid perspective strength should restore the finite default.")
        print("PASS: \(recoveredTargets) independently projected visible targets recovered; strength endpoints, reduced displacement, and clipping checked.")
    }

    @MainActor
    private static func verifyGPU(_ renderer: PlaneRenderer, output: URL) throws {
        renderer.calibration.perspective = 1
        let width = 256
        let height = 160
        var frame: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:]]
        try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                    attributes as CFDictionary, &frame) == kCVReturnSuccess, "Could not allocate the test image.")
        guard let frame else { throw CheckFailure(message: "Missing test image.") }
        CVPixelBufferLockBaseAddress(frame, [])
        let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        // Top-left red; top-right green; bottom-left blue; bottom-right yellow.
        // These literal pixel colors are the oracle, independent of Core Graphics orientation.
        for y in 0..<height {
            for x in 0..<width {
                let red: UInt8 = (y < height / 2 && x < width / 2) || (y >= height / 2 && x >= width / 2) ? 255 : 0
                let green: UInt8 = x >= width / 2 ? 255 : 0
                let blue: UInt8 = y >= height / 2 && x < width / 2 ? 255 : 0
                let offset = y * stride + x * 4
                bytes[offset] = blue; bytes[offset + 1] = green; bytes[offset + 2] = red; bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        try renderer.setFrame(frame)
        renderer.degrees = 90
        let identityURL = output.appendingPathComponent("gpu-identity.png")
        try renderer.renderPNG(to: identityURL, width: width, height: height)
        guard let image = NSBitmapImageRep(data: try Data(contentsOf: identityURL)) else { throw CheckFailure(message: "GPU output PNG could not be read.") }
        let expectations: [(Int, Int, SIMD3<Float>)] = [
            (24, 24, SIMD3(1, 0, 0)), (232, 24, SIMD3(0, 1, 0)),
            (24, 136, SIMD3(0, 0, 1)), (232, 136, SIMD3(1, 1, 0))]
        for (x, y, expected) in expectations {
            var components = [Int](repeating: 0, count: image.samplesPerPixel)
            image.getPixel(&components, atX: x, y: y)
            let actual = SIMD3<Float>(Float(components[0]), Float(components[1]), Float(components[2])) / 255
            try check(simd_distance(actual, expected) < 0.02, "GPU identity/orientation/color check failed at (\(x),\(y)): \(actual).")
        }
        // Independent worked geometry: at 60°, output (.25,.375) looks through
        // the tilted panel to the lower-left of the upright image (blue), although
        // an identity or opposite-cosine shader would show upper-left red there.
        renderer.calibration.frost = 0
        renderer.degrees = 60
        let perspectiveURL = output.appendingPathComponent("gpu-perspective.png")
        try renderer.renderPNG(to: perspectiveURL, width: width, height: height)
        let perspective = NSBitmapImageRep(data: try Data(contentsOf: perspectiveURL))!
        let perspectiveExpectations: [(Int, Int, SIMD3<Float>)] = [
            (64, 60, SIMD3(0, 0, 1)), (192, 60, SIMD3(1, 1, 0)),
            (5, 16, SIMD3(0, 0, 0))]
        for (x, y, expected) in perspectiveExpectations {
            var components = [Int](repeating: 0, count: perspective.samplesPerPixel)
            perspective.getPixel(&components, atX: x, y: y)
            let actual = SIMD3<Float>(Float(components[0]), Float(components[1]), Float(components[2])) / 255
            try check(simd_distance(actual, expected) < 0.02,
                      "GPU perspective disagrees with the independent 60° ray projection at (\(x),\(y)): \(actual).")
        }
        renderer.calibration.perspective = 0
        let uncorrectedURL = output.appendingPathComponent("gpu-perspective-zero.png")
        try renderer.renderPNG(to: uncorrectedURL, width: width, height: height)
        let uncorrected = NSBitmapImageRep(data: try Data(contentsOf: uncorrectedURL))!
        var zeroPixel = [Int](repeating: 0, count: uncorrected.samplesPerPixel)
        uncorrected.getPixel(&zeroPixel, atX: 64, y: 60)
        try check(zeroPixel[0] == 255 && zeroPixel[1] == 0 && zeroPixel[2] == 0,
                  "Zero GPU perspective should show the original red quadrant at60°, not the corrected blue quadrant.")
        renderer.calibration.perspective = 0.55
        let softenedURL = output.appendingPathComponent("gpu-perspective-55.png")
        try renderer.renderPNG(to: softenedURL, width: width, height: height)
        let softened = NSBitmapImageRep(data: try Data(contentsOf: softenedURL))!
        for (x, y) in [(64, 60), (18, 16)] {
            var components = [Int](repeating: 0, count: softened.samplesPerPixel)
            softened.getPixel(&components, atX: x, y: y)
            try check(components[0] > 250 && components[1] < 5 && components[2] < 5,
                      "The55% GPU correction should preserve red at(\(x),\(y)); full correction would move or clip it.")
        }
        renderer.calibration.perspective = 1
        renderer.calibration.frost = 1
        renderer.degrees = 120
        renderer.degrees = 75
        let closingURL = output.appendingPathComponent("gpu-closing.png")
        try renderer.renderPNG(to: closingURL, width: width, height: height)
        renderer.degrees = 15
        renderer.degrees = 75
        let openingURL = output.appendingPathComponent("gpu-opening.png")
        try renderer.renderPNG(to: openingURL, width: width, height: height)
        try check(try Data(contentsOf: closingURL) == Data(contentsOf: openingURL),
                  "The same angle renders differently after reopening; the effect must not depend on direction history.")
        renderer.degrees = 30
        let closedURL = output.appendingPathComponent("gpu-closed.png")
        try renderer.renderPNG(to: closedURL, width: width, height: height)
        let closed = NSBitmapImageRep(data: try Data(contentsOf: closedURL))!
        for (x, y, _) in expectations {
            var components = [Int](repeating: 0, count: closed.samplesPerPixel)
            closed.getPixel(&components, atX: x, y: y)
            try check(components[0] + components[1] + components[2] == 0,
                      "The GPU showed content after the closing fade completed.")
        }
        renderer.clearFrame()
        renderer.degrees = 90
        let clearURL = output.appendingPathComponent("gpu-cleared.png")
        try renderer.renderPNG(to: clearURL, width: width, height: height)
        try check(try Data(contentsOf: clearURL) == Data(contentsOf: closedURL),
                  "Clearing a captured frame must produce opaque black, not retain desktop pixels.")
        renderer.calibration = ViewCalibration()
        try renderer.useTestPattern()
        for angle: Float in [90, 75, 60, 45, 30] {
            renderer.degrees = angle
            try renderer.renderPNG(to: output.appendingPathComponent("calibration-\(Int(angle)).png"), width: 1200, height: 750)
        }
        renderer.degrees = 45
        renderer.calibration.frost = 0
        try renderer.renderPNG(to: output.appendingPathComponent("calibration-45-sharp.png"), width: 1200, height: 750)
        renderer.calibration.frost = 1
    }

    @MainActor
    private static func verifyFrost(_ renderer: PlaneRenderer, output: URL) throws {
        let width = 640
        let height = 400
        var checker: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:]]
        try check(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &checker) == kCVReturnSuccess, "Could not allocate the blur test image.")
        CVPixelBufferLockBaseAddress(checker!, [])
        let bytes = CVPixelBufferGetBaseAddress(checker!)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(checker!)
        // A known high-frequency signal: 20-pixel black and white checkerboard.
        // Gaussian diffusion must reduce its contrast, without needing a reference blur implementation.
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = ((x / 20 + y / 20) % 2 == 0) ? 0 : 255
                let offset = y * stride + x * 4
                bytes[offset] = value; bytes[offset + 1] = value
                bytes[offset + 2] = value; bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(checker!, [])
        try renderer.setFrame(checker!)
        weak let retainedImage: AnyObject? = checker
        checker = nil

        func contrast(_ image: NSBitmapImageRep, yRange: Range<Int>) -> Double {
            var total = 0.0
            var squares = 0.0
            var count = 0.0
            var components = [Int](repeating: 0, count: image.samplesPerPixel)
            for y in yRange {
                for x in (width / 4)..<(width * 3 / 4) {
                    image.getPixel(&components, atX: x, y: y)
                    let value = Double(components[0]) / 255
                    total += value; squares += value * value; count += 1
                }
            }
            return sqrt(max(0, squares / count - pow(total / count, 2)))
        }
        var upperRatios: [Double] = []
        var lowerRatio = 0.0
        for angle: Float in [85, 75, 60, 45] {
            var upper: [Double] = []
            var lower: [Double] = []
            for strength: Float in [0, 1] {
                renderer.degrees = angle
                renderer.calibration.frost = strength
                let url = output.appendingPathComponent("checker-\(Int(angle))-frost\(Int(strength)).png")
                try renderer.renderPNG(to: url, width: width, height: height)
                let image = NSBitmapImageRep(data: try Data(contentsOf: url))!
                upper.append(contrast(image, yRange: 30..<150))
                lower.append(contrast(image, yRange: 330..<380))
            }
            try check(upper[0] > 0.4, "Zero frost unexpectedly blurred the projected checkerboard.")
            upperRatios.append(upper[1] / upper[0])
            if angle == 60 { lowerRatio = lower[1] / lower[0] }
        }
        try check(upperRatios[0] > upperRatios[1] && upperRatios[1] > upperRatios[2],
                  "Checkerboard diffusion did not increase progressively while closing: \(upperRatios).")
        try check(upperRatios[2] < 0.35, "The upper screen still has too much fine detail at 60°.")
        try check(upperRatios[3] < upperRatios[2] && upperRatios[3] < 0.1,
                  "The45° screen should have strong Gaussian diffusion away from the hinge.")
        try check(lowerRatio > upperRatios[2] + 0.25,
                  "The hinge should retain more detail than the upper screen.")
        try check(retainedImage != nil, "The renderer released its snapshot before the gesture ended.")
        renderer.clearFrame()
        try check(retainedImage == nil, "The renderer retained its snapshot after clearFrame.")
        renderer.calibration.frost = 1
        print("PASS: Gaussian blur upper contrast ratios at85/75/60/45° = \(upperRatios.map { String(format: "%.3f", $0) }.joined(separator: ", ")); hinge at60° = \(String(format: "%.3f", lowerRatio)). Snapshot released on clear.")
    }


    @MainActor
    private static func verifyFortyFiveBrightness(_ renderer: PlaneRenderer, output: URL) throws {
        var white: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:]]
        try check(CVPixelBufferCreate(kCFAllocatorDefault, 320, 200, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &white) == kCVReturnSuccess, "Could not allocate the luminance test image.")
        CVPixelBufferLockBaseAddress(white!, [])
        memset(CVPixelBufferGetBaseAddress(white!), 255, CVPixelBufferGetBytesPerRow(white!) * 200)
        CVPixelBufferUnlockBaseAddress(white!, [])
        try renderer.setFrame(white!)
        renderer.calibration = ViewCalibration()
        renderer.degrees = 45
        let url = output.appendingPathComponent("gpu-45-lit-white.png")
        try renderer.renderPNG(to: url, width: 320, height: 200)
        let image = NSBitmapImageRep(data: try Data(contentsOf: url))!
        for (x, y) in [(80, 30), (160, 100), (240, 170)] {
            var components = [Int](repeating: 0, count: image.samplesPerPixel)
            image.getPixel(&components, atX: x, y: y)
            try check(components[0] >= 250 && components[1] >= 250 && components[2] >= 250,
                      "The45° GPU output dims a white screen despite the confirmed viewpoint.")
        }
        renderer.clearFrame()
        print("PASS: fully lit45° Gaussian-blurred GPU output preserves white-field luminance.")
    }

    @MainActor
    private static func verifyPreparation() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = MTKView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = view
        let renderer = try PlaneRenderer(view: view)
        renderer.degrees = 90
        try renderer.useTestPattern()
        try check(!renderer.isReadyForPresentation,
                  "Uploading a snapshot must not mark an unrendered drawable ready.")
        let started = ProcessInfo.processInfo.systemUptime
        try await renderer.prepareForPresentation()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try check(renderer.isReadyForPresentation && !window.isVisible,
                  "First-frame preparation must finish while the window remains hidden.")
        // A subsequent gesture must wait for its own image, never reuse readiness.
        try renderer.useTestPattern()
        try check(!renderer.isReadyForPresentation, "Replacing the snapshot retained stale presentation readiness.")
        try await renderer.prepareForPresentation()
        renderer.clearFrame()
        try check(!renderer.isReadyForPresentation, "Clearing the snapshot retained presentation readiness.")
        do {
            try await renderer.prepareForPresentation()
            throw CheckFailure(message: "An empty renderer was incorrectly prepared for presentation.")
        } catch is CheckFailure { throw CheckFailure(message: "An empty renderer was incorrectly prepared for presentation.") }
        catch { /* Missing snapshots fail before any drawable can be exposed. */ }
        try renderer.useTestPattern()
        let cancelledPreparation = Task { try await renderer.prepareForPresentation() }
        cancelledPreparation.cancel()
        do {
            try await cancelledPreparation.value
            throw CheckFailure(message: "A cancelled gesture became ready for presentation.")
        } catch is CancellationError { /* The abandoned gesture never becomes visible. */ }
        try check(!renderer.isReadyForPresentation, "Cancellation marked the drawable ready.")
        renderer.clearFrame()
        window.close()
        print("PASS: first drawable prepared in a hidden window in\(String(format: "%.1f", elapsed * 1000))ms; replacement, clear, and cancellation invalidate readiness.")
    }

}
