import Foundation

/// Fades in a prepared screenshot while always projecting the current lid angle.
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
        return Frame(degrees: target,
                     opacity: ease(elapsed / 0.1))
    }

    // Zero slope and acceleration at both ends keep the opacity change gentle.
    private func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}
