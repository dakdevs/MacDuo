import Foundation

/// Starts at the unchanged desktop, even if capture finishes after the lid has moved on.
struct EffectTransition {
    struct Frame {
        let degrees: Double
        let opacity: Double
    }

    private(set) var startedAt: TimeInterval?

    mutating func reset() { startedAt = nil }

    mutating func frame(targetDegrees: Double, at timestamp: TimeInterval) -> Frame {
        if startedAt == nil { startedAt = timestamp }
        let elapsed = max(0, timestamp - startedAt!)
        let target = min(90, max(0, targetDegrees))
        return Frame(degrees: 90 + (target - 90) * ease(elapsed / 0.22),
                     opacity: ease(elapsed / 0.1))
    }

    // Zero velocity and acceleration at both ends avoid a kick when tracking takes over.
    private func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}
