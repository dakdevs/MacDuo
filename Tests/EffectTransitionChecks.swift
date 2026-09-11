import Foundation

@main struct EffectTransitionChecks {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    static func main() {
        // A late screenshot must still enter from the unchanged desktop.
        var transition = EffectTransition()
        let first = transition.frame(targetDegrees: 65, at: 100)
        require(first.degrees == 90 && first.opacity == 0, "late entry must start flat and transparent")
        var previous = first
        var maximumStep = 0.0
        for index in 1...40 {
            let frame = transition.frame(targetDegrees: 65, at: 100 + Double(index) / 120)
            require(frame.degrees <= previous.degrees && frame.degrees >= 65, "entry must approach the target without overshooting")
            require(frame.opacity >= previous.opacity && frame.opacity <= 1, "opacity must rise without a flash")
            maximumStep = max(maximumStep, previous.degrees - frame.degrees)
            if index == 1 { require(previous.degrees - frame.degrees < 0.03, "entry must ease in, not start with linear velocity") }
            previous = frame
        }
        require(maximumStep < 1.8, "a delayed 25-degree entry must not jump between frames")
        require(previous.degrees == 65 && previous.opacity == 1, "entry must finish and restore direct tracking")
        let reopened = transition.frame(targetDegrees: 85, at: 101)
        require(reopened.degrees == 85, "completed entry must track reopening, not keep an old target")
        transition.reset()
        let reentry = transition.frame(targetDegrees: 45, at: 105)
        require(reentry.degrees == 90 && reentry.opacity == 0, "reentry after a hide must not inherit the old clock")

        // A moving target must remain continuous at the end of the entry curve.
        var moving = EffectTransition()
        var frames: [Double] = []
        for index in 0...60 {
            let time = Double(index) / 120
            frames.append(moving.frame(targetDegrees: 89 - 30 * time, at: time).degrees)
        }
        for index in 1..<frames.count {
            require(frames[index - 1] - frames[index] < 0.75, "entry handoff must not snap to a moving target")
            if index >= 28 {
                require(frames[index - 1] - frames[index] < 0.27, "tracking must join the 30-degree/second target without an end jump")
            }
        }
        require(abs(frames.last! - 74) < 0.001, "entry must catch up to the current angle")
        print("PASS: late-frame entry, eased opacity/geometry, moving-target handoff, and reentry")
    }
}
