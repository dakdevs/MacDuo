import Foundation

/// Smooths quantized measurements and predicts only the short interval between sensor reads.
/// Capture and visibility decisions must continue to use the measured angle.
struct LidMotion {
    private struct Estimate {
        var position: Double
        var velocity: Double
        var measured: Double
        var timestamp: TimeInterval
    }

    private var estimate: Estimate?
    private static let maximumVelocity = 500.0

    mutating func reset() {
        estimate = nil
    }

    mutating func observe(degrees: Double, at timestamp: TimeInterval) {
        guard degrees.isFinite, (0...180).contains(degrees), timestamp.isFinite, timestamp >= 0 else {
            reset()
            return
        }
        guard var current = estimate else {
            estimate = Estimate(position: degrees, velocity: 0, measured: degrees, timestamp: timestamp)
            return
        }
        let elapsed = timestamp - current.timestamp
        guard elapsed > 0 else { return }
        // After a missed run of reports, old momentum no longer describes the lid.
        guard elapsed <= 0.12 else {
            estimate = Estimate(position: degrees, velocity: 0, measured: degrees, timestamp: timestamp)
            return
        }

        let measuredStep = degrees - current.measured
        if abs(measuredStep) >= 1, measuredStep * current.velocity < 0 {
            current.velocity = 0
        }
        let predicted = current.position + current.velocity * elapsed
        let residual = degrees - predicted
        // These gains are defined at 60 Hz and adjusted for irregular sample intervals.
        let alpha = 1 - pow(0.5, elapsed * 60)
        let beta = 0.12 * min(elapsed * 60, 1)
        let corrected = predicted + alpha * residual
        let maximumStep = Self.maximumVelocity * elapsed
        current.position = min(180, max(0, min(current.position + maximumStep,
                                               max(current.position - maximumStep, corrected))))
        current.velocity = min(Self.maximumVelocity, max(-Self.maximumVelocity,
                                 current.velocity + beta * residual / elapsed))
        current.measured = degrees
        current.timestamp = timestamp
        estimate = current
    }

    func value(at timestamp: TimeInterval) -> Double? {
        guard let estimate, timestamp.isFinite else { return nil }
        let age = timestamp - estimate.timestamp
        guard age >= 0, age <= 0.5 else { return nil }
        let displacement = min(2, max(-2, estimate.velocity * min(age, 0.04)))
        return min(180, max(0, estimate.position + displacement))
    }
}
