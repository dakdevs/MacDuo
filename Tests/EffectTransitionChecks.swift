import Foundation

@main struct EffectTransitionChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        // A captured frame can arrive after a fast close to 39°. Its projection
        // must already match that angle, even while opacity is still zero.
        var transition = EffectTransition()
        let first = transition.frame(targetDegrees: 39, at: 100)
        require(first.degrees == 39 && first.opacity == 0, "late entry must start at the current angle and transparent")
        var previousOpacity = first.opacity
        for index in 1...40 {
            let frame = transition.frame(targetDegrees: 39, at: 100 + Double(index) / 120)
            require(frame.degrees == 39, "visible entry must not project a 39-degree lid at an invented angle")
            require(frame.opacity >= previousOpacity && frame.opacity <= 1, "opacity must rise without a flash")
            if index == 1 { require(frame.opacity < 0.01, "opacity must ease in without an initial linear jump") }
            if index == 6 { require(abs(frame.opacity - 0.5) < 0.000001, "the 100ms opacity fade must be halfway at 50ms") }
            if index >= 13 { require(frame.opacity == 1, "opacity must finish after 100ms") }
            previousOpacity = frame.opacity
        }
        let reopened = transition.frame(targetDegrees: 85, at: 101)
        require(reopened.degrees == 85, "completed entry must track reopening, not keep an old target")
        transition.reset()
        let reentry = transition.frame(targetDegrees: 45, at: 105)
        require(reentry.degrees == 45 && reentry.opacity == 0, "reset must restart opacity without changing geometry")
        require(transition.frame(targetDegrees: 60, at: 105.05).degrees == 60,
                "reentry must continue following the current angle")

        // Physical angles supplied during a fast close and reversal. The angle
        // filter owns smoothing; presentation must not add another delay.
        var moving = EffectTransition()
        let trajectory: [(time: Double, angle: Double)] = [
            (0, 89), (0.0167, 81), (0.05, 60), (0.0833, 39),
            (0.12, 60), (0.20, 85), (0.30, 88)
        ]
        for sample in trajectory {
            let frame = moving.frame(targetDegrees: sample.angle, at: sample.time)
            require(frame.degrees == sample.angle, "entry delayed a moving or reversing target at \(sample.time)s")
        }
        for (input, expected) in [(-20.0, 0.0), (0, 0), (45, 45), (90, 90), (180, 90)] {
            var bounded = EffectTransition()
            for time in [0.0, 0.05, 0.1, 10] {
                let frame = bounded.frame(targetDegrees: input, at: time)
                require(frame.degrees == expected, "entry escaped the supported 0...90 degree bounds")
                require((0...1).contains(frame.opacity), "entry opacity escaped 0...1")
            }
        }
        print("PASS: exact-angle late entry and fast closing, direct moving-target tracking, eased opacity, reset, and bounds")
    }
}
