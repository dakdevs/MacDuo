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
        setbuf(stdout, nil)
        try stationary()
        try ramps()
        try heldReports()
        try jitteredReports()
        try heldStationaryNoise()
        try heldStopAndReversal()
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
            try require(abs(motion.value(at: last + 0.3)! - reading) < 0.000001,
                        "Prediction did not settle back to the final held measurement.")
        }
    }

    private static func heldReports() throws {
        // The device refreshes at10Hz, while polling and display use60/120Hz.
        // Compare against independently defined physical motion at presentation time.
        for speed in [15.0, 30, 60] {
            for direction in [-1.0, 1] {
                for lead in [0.0, 1.0 / 120, 0.025] {
                    var motion = LidMotion()
                    var reading = direction < 0 ? 160.0 : 20.0
                    let origin = reading
                    var previous: Double?
                    var errors: [Double] = []
                    var largestStep = 0.0
                    for frame in 0..<240 {
                        let time = Double(frame) / 120
                        if frame.isMultiple(of: 12) { reading = (origin + direction * speed * time).rounded() }
                        if frame.isMultiple(of: 2) {
                            let before = motion.value(at: time)
                            motion.observe(degrees: reading, at: time)
                            if let before {
                                try require(abs(motion.value(at: time)! - before) < 0.000001,
                                            "A changed report jumped the rendered position.")
                            }
                        }
                        let value = motion.value(at: time + lead)!
                        if time >= 0.5 {
                            errors.append(value - (origin + direction * speed * (time + lead)))
                            if let previous {
                                let step = direction * (value - previous)
                                try require(step >= -0.000001, "A constant held ramp moved in the wrong direction.")
                                largestStep = max(largestStep, step)
                            }
                            previous = value
                        }
                    }
                    let bias = errors.reduce(0, +) / Double(errors.count)
                    let rms = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
                    try require(abs(bias) < 0.35 && rms < 0.55,
                                "Held \(speed)°/s motion has excessive lag: bias \(bias), RMS \(rms).")
                    try require(largestStep < max(0.5, speed / 120 * 2.5),
                                "A report arrival produced a visible multi-degree catch-up step: \(largestStep) at speed \(speed), lead \(lead).")
                    print("held speed=\(speed), direction=\(direction), lead=\(lead): bias=\(bias), rms=\(rms), largestStep=\(largestStep)")
                }
            }
        }
    }

    private static func jitteredReports() throws {
        // Refresh intervals alternate83/117ms, independently of the120Hz display.
        for speed in [15.0, 30, 60] {
            var motion = LidMotion()
            var reading = 160.0
            var nextReport = 0
            var reportIndex = 0
            var previous: Double?
            var errors: [Double] = []
            for frame in 0..<240 {
                let time = Double(frame) / 120
                if frame == nextReport {
                    reading = (160 - speed * time).rounded()
                    nextReport += reportIndex.isMultiple(of: 2) ? 10 : 14
                    reportIndex += 1
                }
                if frame.isMultiple(of: 2) {
                    let before = motion.value(at: time)
                    motion.observe(degrees: reading, at: time)
                    if let before {
                        try require(abs(motion.value(at: time)! - before) < 0.000001,
                                    "An irregular report jumped the rendered position.")
                    }
                }
                let value = motion.value(at: time + 1.0 / 120)!
                if time >= 0.5 {
                    if let previous {
                        try require(value <= previous + 0.000001,
                                    "Polling jitter reversed a constant \(speed)°/s ramp.")
                    }
                    previous = value
                    errors.append(value - (160 - speed * (time + 1.0 / 120)))
                }
            }
            let rms = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
            try require(rms < 0.75, "Irregular report timing caused excessive tracking error: \(rms).")
            print("jittered speed=\(speed): RMS=\(rms)")
        }
    }

    private static func heldStationaryNoise() throws {
        var motion = LidMotion()
        var values: [Double] = []
        for frame in 0..<600 {
            let time = Double(frame) / 120
            let reading = (frame / 12).isMultiple(of: 2) ? 102.0 : 103.0
            if frame.isMultiple(of: 2) { motion.observe(degrees: reading, at: time) }
            let value = motion.value(at: time + 1.0 / 120)!
            if time >= 0.5 { values.append(value) }
        }
        try require(variance(values) < 0.01, "Stationary10Hz quantization toggles generated momentum.")
        try require(values.allSatisfy { (102...103).contains($0) }, "Stationary noise was extrapolated beyond the readings.")
        for frame in 600..<840 {
            let time = Double(frame) / 120
            if frame.isMultiple(of: 2) { motion.observe(degrees: 102, at: time) }
            try require(motion.value(at: time) != nil, "A stationary lid expired despite fresh HID polls.")
            if time >= 5.3 {
                try require(abs(motion.value(at: time)! - 102) < 0.000001,
                            "Noise suppression left a permanent offset after the sensor settled.")
            }
        }
    }

    private static func heldStopAndReversal() throws {
        for reverse in [false, true] {
            var motion = LidMotion()
            var reading = 120.0
            var overshoot = 0.0
            var previousAfterReversal: Double?
            for frame in 0..<240 {
                let time = Double(frame) / 120
                let physical = time <= 1 ? 120 - 60 * time : (reverse ? 60 + 60 * (time - 1) : 60)
                if frame.isMultiple(of: 12) { reading = physical.rounded() }
                if frame.isMultiple(of: 2) { motion.observe(degrees: reading, at: time) }
                let value = motion.value(at: time)!
                if time >= 1 { overshoot = max(overshoot, max(0, 60 - value)) }
                if reverse && time >= 1.15 {
                    try require(abs(value - physical) < 1, "A visible reversal retained old momentum.")
                    if let previousAfterReversal {
                        try require(value >= previousAfterReversal - 0.000001,
                                    "The trajectory reversed again after the opening report.")
                    }
                    previousAfterReversal = value
                }
                if !reverse && time >= 1.25 {
                    try require(abs(value - 60) < 0.000001, "A stopped lid retained predicted displacement.")
                }
            }
            try require(overshoot <= 8.000001, "Unseen stop/reversal exceeded the eight-degree prediction cap.")
            print("held reverse=\(reverse): maximum unseen-stop overshoot=\(overshoot)")
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
                try require(abs(value - physical) < 1.2, "A reversal retained old momentum for too long at \(time): angle \(value), physical \(physical).")
            }
            if time >= 1.3 {
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
