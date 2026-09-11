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
        try responseToChangingSpeed()
        try recordedStopTiming()
        try noiseAfterMovement()
        try reversalAndStop()
        try gapsAndInvalidInput()
        print("PASS: stationary noise, held and jittered reports, continuous interpolation, acceleration, natural slowdown, stop phases, reversal, freshness, gaps, reset, and physical bounds.")
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
            // Actual unchanged polls establish a stop; rendering into the future
            // alone must not be mistaken for new information from the sensor.
            for index in 1...18 {
                motion.observe(degrees: reading, at: last + Double(index) / 60)
            }
            try require(abs(motion.value(at: last + 0.3)! - reading) < 0.000001,
                        "Prediction did not settle after unchanged sensor polls established a stop.")
        }
    }

    private static func heldReports() throws {
        // The device refreshes at10Hz, while polling and display use60/120Hz.
        // Compare against independently defined physical motion at presentation time.
        for speed in [8.0, 15, 30, 60] {
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
                                try require(step >= -0.000001, "A constant held \(speed)°/s ramp moved in the wrong direction at \(time), lead \(lead): \(step).")
                                largestStep = max(largestStep, step)
                            }
                            previous = value
                        }
                    }
                    let bias = errors.reduce(0, +) / Double(errors.count)
                    let rms = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
                    try require(abs(bias) < (speed == 8 ? 0.75 : 0.35) && rms < (speed == 8 ? 0.8 : 0.55),
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
        for speed in [8.0, 15, 30, 60] {
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

    private static func responseToChangingSpeed() throws {
        // Independently integrate physical acceleration, then quantize only the
        // sensor samples. The oracle remains continuous at presentation time.
        for acceleration in [60.0, 90] {
            var motion = LidMotion()
            var reading = 160.0
            var errors: [Double] = []
            for frame in 0..<144 {
                let time = Double(frame) / 120
                if frame.isMultiple(of: 12) { reading = (160 - 0.5 * acceleration * time * time).rounded() }
                if frame.isMultiple(of: 2) { motion.observe(degrees: reading, at: time) }
                let presentation = time + 1.0 / 120
                if time >= 0.5 {
                    errors.append(motion.value(at: presentation)! - (160 - 0.5 * acceleration * presentation * presentation))
                }
            }
            let rms = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
            try require(rms < (acceleration == 60 ? 0.9 : 1.25),
                        "Velocity averaging added excessive acceleration lag: RMS \(rms).")
        }

        // The stop can happen anywhere between two hardware refreshes.
        for stopTime in [1.0, 1.025, 1.05, 1.075] {
            var motion = LidMotion()
            var reading = 140.0
            let stoppedAngle = 140 - 60 * stopTime
            var overshoot = 0.0
            for frame in 0..<180 {
                let time = Double(frame) / 120
                if frame.isMultiple(of: 12) { reading = (140 - 60 * min(time, stopTime)).rounded() }
                if frame.isMultiple(of: 2) {
                    let before = motion.value(at: time)
                    motion.observe(degrees: reading, at: time)
                    if let before {
                        try require(abs(motion.value(at: time)! - before) < 0.000001,
                                    "Confirming a stop jumped the rendered position.")
                    }
                }
                let value = motion.value(at: time)!
                if time >= stopTime { overshoot = max(overshoot, stoppedAngle - value) }
                if time >= stopTime + 0.26 {
                    try require(abs(value - stoppedAngle.rounded()) < 0.000001,
                                "An offset-phase stop retained motion beyond260ms.")
                }
            }
            // This includes both the forecast and the reconciliation curve.
            try require(overshoot < 9.5, "An abrupt stop exceeded the tested total-trajectory bound.")
        }

        // Close at60°/s, slow linearly to zero over300ms, then hold at89°.
        var motion = LidMotion()
        var reading = 140.0
        var errors: [Double] = []
        var overshoot = 0.0
        for frame in 0..<180 {
            let time = Double(frame) / 120
            let slowingTime = min(0.3, max(0, time - 0.7))
            let physical = 140 - 60 * min(time, 0.7) - 60 * slowingTime + 100 * slowingTime * slowingTime
            if frame.isMultiple(of: 12) { reading = physical.rounded() }
            if frame.isMultiple(of: 2) { motion.observe(degrees: reading, at: time) }
            let value = motion.value(at: time)!
            if time >= 0.7 && time <= 1 { errors.append(value - physical) }
            if time >= 1 { overshoot = max(overshoot, 89 - value) }
            if time >= 1.18 {
                try require(abs(value - 89) < 0.000001,
                            "A natural slowdown kept drifting after unchanged polls established a stop.")
            }
        }
        let rms = sqrt(errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count))
        try require(rms < 2.4 && overshoot < 6.5,
                    "The trajectory retained too much old velocity during a natural slowdown.")
    }

    private static func recordedStopTiming() throws {
        // A shortened recorded60Hz poll trace from a15°/s opening gesture.
        // Its last two report intervals are105ms and95ms; physical motion stops
        // at5.6s. Tiny timing changes must not add an entire device refresh.
        let polls: [(Double, Double)] = [
            (5.105148,81),(5.121827,81),(5.138481,81),(5.155426,81),(5.172997,81),(5.189849,81),
            (5.200278,82),(5.216938,82),(5.233590,82),(5.250262,82),(5.266936,82),(5.283606,82),
            (5.300300,84),(5.330125,84),(5.333606,84),(5.350298,84),(5.366948,84),(5.383601,84),
            (5.400268,85),(5.421797,85),(5.438436,85),(5.455161,85),(5.471815,85),(5.488467,85),
            (5.505163,87),(5.521789,87),(5.538464,87),(5.555125,87),(5.572219,87),(5.589804,87),
            (5.600303,88),(5.616975,88),(5.633618,88),(5.650302,88),(5.666943,88),(5.683623,88),
            (5.700318,88),(5.716984,88),(5.733620,88),(5.750294,88),(5.766979,88),(5.783618,88),
            (5.800281,88),(5.816928,88),(5.833592,88),(5.850262,88),(5.866938,88),(5.888682,88)
        ]
        var motion = LidMotion()
        var pollIndex = 0
        for frame in 0..<94 {
            let time = 5.11 + Double(frame) / 120
            while pollIndex < polls.count && polls[pollIndex].0 <= time {
                let poll = polls[pollIndex]
                motion.observe(degrees: poll.1, at: poll.0)
                pollIndex += 1
            }
            let value = motion.value(at: time + 1.0 / 120)!
            if time >= 5.8 {
                try require(abs(value - 88) < 0.1,
                            "Small poll jitter added a full refresh to the15°/s stop deadline: angle \(value).")
            }
        }
    }

    private static func noiseAfterMovement() throws {
        // Close at15°/s to90°, then let an unchanged poll establish a stop.
        // Sensor noise starts just after that confirmation, when stale movement
        // confidence could otherwise mistake the first1° change for a reversal.
        var motion = LidMotion()
        var reading = 105.0
        var values: [Double] = []
        for frame in 0..<420 {
            let time = Double(frame) / 120
            if frame <= 120 && frame.isMultiple(of: 12) { reading = (105 - 15 * time).rounded() }
            if frame >= 136 { reading = ((frame - 136) / 12).isMultiple(of: 2) ? 91 : 89 }
            if frame.isMultiple(of: 2) { motion.observe(degrees: reading, at: time) }
            if time >= 1.6 { values.append(motion.value(at: time + 1.0 / 120)!) }
        }
        try require(values.allSatisfy { (89...91).contains($0) },
                    "Stationary noise after a gesture inherited old movement momentum.")
        try require(variance(values) < 0.05,
                    "Alternating one-degree noise restarted motion after a confirmed stop.")
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
