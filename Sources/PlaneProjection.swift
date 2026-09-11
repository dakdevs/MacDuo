import Foundation
import simd

struct ViewCalibration {
    var distanceCM: Float = 60
    var heightCM: Float = 34
    var screenHeightCM: Float = 22.4
    var frost: Float = 1
    var perspective: Float = 1
}

/// Projects a physical panel pixel onto the fixed upright desktop, through one eye point.
/// UVs have a top-left origin. Distances are normalized to one physical panel height.
struct PlaneProjection {
    let degrees: Float
    let calibration: ViewCalibration

    // Metal receives these same scalars: (eye distance, sin(angle), cos(angle), eye height).
    var rayCoefficients: SIMD4<Float> {
        let angle = min(90, max(0, degrees.isFinite ? degrees : 90))
        let radians = angle * .pi / 180
        return SIMD4(calibration.distanceCM / calibration.screenHeightCM,
                     angle == 90 ? 1 : sin(radians),
                     angle == 90 ? 0 : cos(radians),
                     calibration.heightCM / calibration.screenHeightCM)
    }

    /// UI values are clamped at this boundary; invalid input restores the default.
    var perspectiveStrength: Float {
        calibration.perspective.isFinite ? min(1, max(0, calibration.perspective)) : 1
    }

    private var isValid: Bool {
        degrees.isFinite && calibration.distanceCM.isFinite && calibration.distanceCM > 0
            && calibration.heightCM.isFinite && calibration.heightCM >= 0
            && calibration.screenHeightCM.isFinite && calibration.screenHeightCM > 0
    }

    func sourceUV(_ panelUV: SIMD2<Float>) -> SIMD2<Float>? {
        guard isValid, panelUV.x.isFinite, panelUV.y.isFinite else { return nil }
        var source = panelUV
        if perspectiveStrength > 0 {
            let ray = rayCoefficients
            let physicalHeight = 1 - panelUV.y
            let denominator = ray.x - physicalHeight * ray.z
            guard denominator > 0.00001 else { return nil }
            let projected = SIMD2<Float>(0.5 + (panelUV.x - 0.5) * ray.x / denominator,
                                          1 - physicalHeight * (ray.x * ray.y - ray.w * ray.z) / denominator)
            source = simd_mix(panelUV, projected, SIMD2(repeating: perspectiveStrength))
        }
        // Clip after blending: a softer correction exposes fewer black side wedges.
        guard source.x.isFinite, source.y.isFinite,
              source.x >= -0.00001, source.x <= 1.00001,
              source.y >= -0.00001, source.y <= 1.00001 else { return nil }
        return source
    }

    /// Dissolve before the physical display becomes edge-on to the assumed viewer.
    var visibility: Float {
        guard isValid else { return 0 }
        if degrees >= 90 { return 1 }
        let grazing = atan2(calibration.heightCM, calibration.distanceCM) * 180 / .pi
        let lower = min(90, grazing + 2)
        let upper = min(90, grazing + 12)
        let fraction = min(1, max(0, (degrees - lower) / max(0.0001, upper - lower)))
        return fraction * fraction * (3 - 2 * fraction)
    }

    var closingAmount: Float {
        guard degrees.isFinite else { return 0 }
        return min(1, max(0, (90 - degrees) / 60))
    }
}
