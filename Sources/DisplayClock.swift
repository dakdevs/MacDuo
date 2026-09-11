import CoreGraphics
import CoreVideo
import Foundation

@MainActor
final class DisplayClock {
    private var link: CVDisplayLink?
    private let bridge: FrameBridge

    init(displayID: CGDirectDisplayID, onFrame: @escaping @MainActor (Double) -> Void) throws {
        bridge = FrameBridge(onFrame: onFrame)
        var created: CVDisplayLink?
        let creation = CVDisplayLinkCreateWithCGDisplay(displayID, &created)
        guard creation == kCVReturnSuccess, let created else {
            throw ClockError(operation: "creation", status: creation)
        }
        link = created
        let frequency = CVGetHostClockFrequency()
        let bridge = bridge
        let installation = CVDisplayLinkSetOutputHandler(created) { _, _, target, _, _ in
            bridge.offer(Double(target.pointee.hostTime) / frequency)
            return kCVReturnSuccess
        }
        guard installation == kCVReturnSuccess else {
            invalidate()
            throw ClockError(operation: "callback installation", status: installation)
        }
        let start = CVDisplayLinkStart(created)
        guard start == kCVReturnSuccess else {
            invalidate()
            throw ClockError(operation: "start", status: start)
        }
    }

    func invalidate() {
        bridge.invalidate()
        if let link { CVDisplayLinkStop(link) }
        link = nil // Releasing the stopped link also releases its retained handler.
    }

    deinit {
        bridge.invalidate()
        if let link { CVDisplayLinkStop(link) }
    }

    private struct ClockError: LocalizedError {
        let operation: String
        let status: CVReturn
        var errorDescription: String? { "Display clock \(operation) failed (\(status))." }
    }
}

// The lock protects only scheduling state. Drawing always runs on the main actor,
// outside the lock, with the gate held closed until the draw finishes.
private final class FrameBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var pending = false
    private var latest: Double = 0
    private let onFrame: @MainActor (Double) -> Void

    init(onFrame: @escaping @MainActor (Double) -> Void) { self.onFrame = onFrame }

    func offer(_ timestamp: Double) {
        lock.lock()
        guard active else { lock.unlock(); return }
        latest = timestamp
        guard !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.lock.lock()
                let timestamp = self.latest
                let active = self.active
                self.lock.unlock()
                if active { self.onFrame(timestamp) }
                self.lock.lock()
                self.pending = false
                self.lock.unlock()
            }
        }
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
