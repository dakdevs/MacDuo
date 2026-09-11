import Foundation

/// Bounded, state-only measurements for an optional diagnostic session.
struct FramePacing {
    private var requestedFramesPerSecond = 0
    private var displayTargets: [Double] = []
    private var presentations: [Double] = []
    private var gpuMilliseconds: [Double] = []
    private static let sampleLimit = 1200

    mutating func reset(requestedFramesPerSecond: Int) {
        self.requestedFramesPerSecond = requestedFramesPerSecond
        displayTargets.removeAll(keepingCapacity: true)
        presentations.removeAll(keepingCapacity: true)
        gpuMilliseconds.removeAll(keepingCapacity: true)
    }

    mutating func recordDisplayTarget(_ timestamp: Double) {
        if displayTargets.count < Self.sampleLimit { displayTargets.append(timestamp) }
    }

    mutating func recordPresentation(at timestamp: Double, gpuDurationMilliseconds: Double) {
        guard timestamp.isFinite, timestamp > 0, presentations.count < Self.sampleLimit else { return }
        presentations.append(timestamp)
        if gpuDurationMilliseconds.isFinite, gpuDurationMilliseconds > 0 {
            gpuMilliseconds.append(gpuDurationMilliseconds)
        }
    }

    var diagnostics: [String: Any] {
        let presented = presentations.sorted()
        let intervals = zip(presented.dropFirst(), presented).map { ($0 - $1) * 1000 }.sorted()
        let frameBudget = requestedFramesPerSecond > 0 ? 1000 / Double(requestedFramesPerSecond) : .infinity
        return [
            "requestedFramesPerSecond": requestedFramesPerSecond,
            "displayLinkSamples": displayTargets.count,
            "presentationSamples": presentations.count,
            "displayLinkFramesPerSecond": framesPerSecond(displayTargets) as Any? ?? NSNull(),
            "presentedFramesPerSecond": framesPerSecond(presented) as Any? ?? NSNull(),
            "presentationIntervalP50MS": percentile(intervals, 0.5) as Any? ?? NSNull(),
            "presentationIntervalP95MS": percentile(intervals, 0.95) as Any? ?? NSNull(),
            "gpuP95MS": percentile(gpuMilliseconds.sorted(), 0.95) as Any? ?? NSNull(),
            "longPresentationIntervals": intervals.filter { $0 > frameBudget * 1.5 }.count
        ]
    }

    private func framesPerSecond(_ timestamps: [Double]) -> Double? {
        guard timestamps.count > 1, let first = timestamps.first, let last = timestamps.last,
              last > first else { return nil }
        return Double(timestamps.count - 1) / (last - first)
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        return sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }
}
