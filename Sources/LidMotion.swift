import Foundation

/// Fills display frames between quantized HID reports. Repeated polls establish
/// liveness and stop detection; changed angles update the motion estimate.
struct LidMotion {
    private struct Report {
        var degrees: Double
        var time: TimeInterval
    }

    private struct Estimate {
        var measured: Double
        var target: Double
        var reportTime: TimeInterval
        var pollTime: TimeInterval
        var velocity = 0.0
        var previousStep = 0.0
        var directionalTravel = 0.0
        var cadence = 0.1
        var positionOffset = 0.0
        var velocityOffset = 0.0
        var correctionDuration = 0.04
        var reports: [Report] = []
        var stopTime: TimeInterval?
        var stopPosition = 0.0
    }

    private var estimate: Estimate?
    private static let maximumVelocity = 500.0
    private static let maximumPrediction = 8.0

    mutating func reset() {
        estimate = nil
    }

    mutating func observe(degrees: Double, at timestamp: TimeInterval) {
        guard degrees.isFinite, (0...180).contains(degrees), timestamp.isFinite, timestamp >= 0 else {
            reset()
            return
        }
        guard var current = estimate else {
            estimate = Estimate(measured: degrees, target: degrees, reportTime: timestamp, pollTime: timestamp)
            return
        }
        let pollInterval = timestamp - current.pollTime
        guard pollInterval > 0 else { return }
        guard pollInterval <= 0.12 else {
            estimate = Estimate(measured: degrees, target: degrees, reportTime: timestamp, pollTime: timestamp)
            return
        }
        current.pollTime = timestamp
        let step = degrees - current.measured
        guard step != 0 else {
            // Decide from an actual poll, never a future presentation timestamp.
            // Slow movement can need several device refreshes to cross a degree;
            // allow another half-degree for the unknown quantization phase.
            // Before velocity is confirmed, wait for two device updates.
            let quantizationDelay = current.velocity == 0
                ? current.cadence * 1.5 : 1.5 / abs(current.velocity)
            let stopDelay = current.cadence
                + 2 * max(0, quantizationDelay - current.cadence) + 1.0 / 60
            if current.stopTime == nil && timestamp - current.reportTime >= stopDelay - 0.000001 {
                current.stopPosition = Self.point(current, at: timestamp).position
                current.stopTime = timestamp
                current.velocity = 0
                current.previousStep = 0
                current.directionalTravel = 0
                current.reports.removeAll(keepingCapacity: true)
            }
            estimate = current
            return
        }

        let interval = timestamp - current.reportTime
        let previous = Self.point(current, at: timestamp)
        // Quantization can alternate between neighboring degrees on a held lid.
        // Require three degrees of travel in one direction before predicting.
        let continuing = step * current.previousStep > 0 && interval <= 0.25
        current.directionalTravel = continuing ? current.directionalTravel + step : step
        if !continuing { current.reports = [Report(degrees: current.measured, time: current.reportTime)] }
        current.reports.append(Report(degrees: degrees, time: timestamp))
        while current.reports.count > 2 && (timestamp - current.reports[0].time > 0.25 || current.reports.count > 16) {
            current.reports.removeFirst()
        }
        let confirmedReversal = step * current.velocity < 0
            && abs(step / interval) >= abs(current.velocity) * 0.4
            && interval <= current.cadence * 1.4
        let moving = abs(current.directionalTravel) >= 3 || confirmedReversal
        let anchor = current.reports[0]
        var velocity = moving && interval <= 0.25 ? (degrees - anchor.degrees) / (timestamp - anchor.time) : 0
        velocity = min(Self.maximumVelocity, max(-Self.maximumVelocity, velocity))
        let target = !moving && abs(step) <= 2 ? (degrees + current.measured) * 0.5 : degrees
        // Report spacing includes quantization: at slow speeds, several device
        // reports can legitimately contain the same angle.
        if interval <= 0.15 {
            current.cadence = min(0.12, max(1.0 / 60, max(interval, current.cadence * 0.9)))
        }
        current.positionOffset = previous.position - target
        current.velocityOffset = previous.velocity - velocity
        current.correctionDuration = max(0.04, abs(current.positionOffset) * 2 / Self.maximumVelocity)
        if continuing && velocity != 0 {
            // A quantized anchor may sit behind the current trajectory. Give the
            // correction enough time to converge without reversing steady motion.
            current.correctionDuration = max(current.correctionDuration,
                                             3 * max(0, current.positionOffset / velocity))
            let secant = velocity - current.positionOffset / current.correctionDuration
            let startVelocity = min(3 * abs(secant), max(0, previous.velocity * (velocity > 0 ? 1 : -1)))
                * (velocity > 0 ? 1 : -1)
            current.velocityOffset = startVelocity - velocity
        }
        current.stopTime = nil
        current.measured = degrees
        current.target = target
        current.reportTime = timestamp
        current.velocity = velocity
        current.previousStep = step
        estimate = current
    }

    func value(at timestamp: TimeInterval) -> Double? {
        guard let estimate, timestamp.isFinite else { return nil }
        let age = timestamp - estimate.pollTime
        guard age >= 0, age <= 0.5 else { return nil }
        return min(180, max(0, Self.point(estimate, at: timestamp).position))
    }

    private static func point(_ estimate: Estimate, at timestamp: TimeInterval) -> (position: Double, velocity: Double) {
        if let stopTime = estimate.stopTime {
            let u = min(1, max(0, timestamp - stopTime) / 0.06)
            let blend = u * u * u * (10 + u * (-15 + 6 * u))
            let displacement = estimate.stopPosition - estimate.measured
            let velocity = -displacement * 30 * u * u * (1 - u) * (1 - u) / 0.06
            return (estimate.measured + displacement * (1 - blend), velocity)
        }
        let age = max(0, timestamp - estimate.reportTime)
        let projected = estimate.velocity * age
        let displacement = min(maximumPrediction, max(-maximumPrediction, projected))
        var velocity = abs(projected) <= maximumPrediction ? estimate.velocity : 0

        // Reconcile the new report without a position or velocity discontinuity.
        let duration = estimate.correctionDuration
        let u = min(1, age / duration)
        let h00 = (2 * u - 3) * u * u + 1
        let h10 = ((u - 2) * u + 1) * u
        let correction = estimate.positionOffset * h00 + estimate.velocityOffset * duration * h10
        velocity += estimate.positionOffset * (6 * u * u - 6 * u) / duration
            + estimate.velocityOffset * (3 * u * u - 4 * u + 1)
        return (estimate.target + displacement + correction, velocity)
    }
}
