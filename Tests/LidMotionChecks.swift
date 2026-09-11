import Foundation

private struct MotionFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw MotionFailure(description: message) }
}

@main
struct LidMotionChecks {
    static func main() throws {
        try stationary()
        try ramps()
        try reversalAndStop()
        try gapsAndInvalidInput()
        print("PASS: stationary noise, quantized physical ramps, interpolation, reversal, stop, bounded prediction, gaps, stale data, reset, and finite output.")
    }

    private static func variance(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
    }

    private static func stationary() throws {
        // A lid held at 80° with occasional one-degree sensor noise.
        let noise = [0.0, 1, 0, 0, -1, 0, 1, 0, -1, 0, 0, 0]
        var motion = LidMotion()
        var measured: [Double] = []
        var rendered: [Double] = []
        for index in 0..<360 {
            let time = Double(index) / 60
            let sample = 80 + noise[index % noise.count]
            motion.observe(degrees: sample, at: time)
            if index > 60 {
                measured.append(sample)
                rendered.append(motion.value(at: time + 1.0 / 120)!)
            }
        }
        try require(variance(rendered) < variance(measured) * 0.55,
                    "Stationary noise should lose at least 45% of its variance.")
        let mean = rendered.reduce(0, +) / Double(rendered.count)
        try require(abs(mean - 80) < 0.15, "Smoothing introduced stationary drift.")
    }

    private static func ramps() throws {
        for speed in [8.0, 30, 90, 240] {
            var motion = LidMotion()
            var errors: [Double] = []
            var rendered: [Double] = []
            var heldReadings: [Double] = []
            let duration = min(2, 90 / speed)
            var reading = 120.0
            for frame in 0...Int(duration * 120) {
                let time = Double(frame) / 120
                let physicalAngle = 120 - speed * time
                if frame.isMultiple(of: 2) {
                    reading = physicalAngle.rounded()
                    motion.observe(degrees: reading, at: time)
                }
                guard let value = motion.value(at: time) else {
                    throw MotionFailure(description: "Fresh ramp output unexpectedly disappeared.")
                }
                if time >= 0.2 {
                    errors.append(value - physicalAngle)
                    rendered.append(value)
                    heldReadings.append(reading)
                }
            }
            let meanError = errors.reduce(0, +) / Double(errors.count)
            let rmsError = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
            try require(abs(meanError) < 0.5 && rmsError < 0.8,
                        "The \(speed)°/s ramp lags or drifts: bias \(meanError), RMS \(rmsError).")
            if speed == 30 {
                func roughness(_ values: [Double]) -> Double {
                    (2..<values.count).map { index in
                        let acceleration = values[index] - 2 * values[index - 1] + values[index - 2]
                        return acceleration * acceleration
                    }.reduce(0, +)
                }
                try require(roughness(rendered) < roughness(heldReadings) * 0.45,
                            "120 Hz interpolation did not remove the quantized staircase.")
            }
            let last = floor(duration * 60) / 60
            let now = motion.value(at: last)!
            let predicted = motion.value(at: last + 0.04)!
            try require(abs(predicted - now) <= 2.000001, "Prediction exceeded two degrees.")
            try require(abs(predicted - motion.value(at: last + 0.3)!) < 0.000001,
                        "Prediction continued after the short extrapolation horizon.")
        }
    }

    private static func reversalAndStop() throws {
        var motion = LidMotion()
        var afterReversal: [Double] = []
        for frame in 0...180 {
            let time = Double(frame) / 120
            // Close at 60°/s, reverse at 90°, then stop at 120°.
            let physical = time <= 0.5 ? 120 - 60 * time : min(120, 90 + 60 * (time - 0.5))
            if frame.isMultiple(of: 2) { motion.observe(degrees: physical.rounded(), at: time) }
            let value = motion.value(at: time)!
            if time >= 0.56, time <= 0.9 { afterReversal.append(value) }
            if time >= 0.56, time < 1 {
                try require(abs(value - physical) < 1.2, "A reversal retained old momentum for too long.")
            }
            if time >= 1.15 {
                try require(abs(value - 120) < 0.2, "The estimator kept moving after the lid stopped.")
            }
        }
        try require(zip(afterReversal, afterReversal.dropFirst()).allSatisfy { $0 <= $1 },
                    "The rendered lid continued closing after a clear reversal.")
    }

    private static func gapsAndInvalidInput() throws {
        var motion = LidMotion()
        try require(motion.value(at: 0) == nil, "An empty estimator produced an angle.")
        for index in 0...20 { motion.observe(degrees: 100 - Double(index), at: Double(index) / 60) }
        try require(motion.value(at: 1) == nil, "Stale samples should stop producing output.")
        motion.observe(degrees: 42, at: 4)
        try require(motion.value(at: 4.04) == 42, "A sample gap carried old closing momentum into a fresh sample.")
        motion.observe(degrees: 150, at: 3.9)
        try require(motion.value(at: 4.04) == 42, "Out-of-order samples changed the current estimate.")
        motion.observe(degrees: 0, at: 4.000000001)
        try require(abs(motion.value(at: 4.000000001)! - 42) < 0.001,
                    "Nearly coincident reports caused an unbounded position jump.")
        try require(motion.value(at: .nan) == nil, "A nonfinite render timestamp was accepted.")
        motion.reset()
        try require(motion.value(at: 4.1) == nil, "Reset retained an old angle.")
        for invalid in [Double.nan, .infinity, -.infinity, -1, 181] {
            motion.observe(degrees: 80, at: 5)
            motion.observe(degrees: invalid, at: 5.01)
            try require(motion.value(at: 5.02) == nil, "Invalid input must invalidate the estimate.")
        }
        for index in 0..<600 {
            let time = 10 + Double(index) / 60
            motion.observe(degrees: Double((index * 71) % 181), at: time)
            let value = motion.value(at: time + 1.0 / 120)!
            try require(value.isFinite && (0...180).contains(value), "An extreme valid report escaped physical bounds.")
        }
    }
}
