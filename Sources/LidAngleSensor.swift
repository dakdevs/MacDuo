import Foundation
import IOKit.hid

struct LidSample {
    let degrees: Double
    let timestamp: TimeInterval
}

final class LidAngleSensor {
    private let queue = DispatchQueue(label: "MacDuo.lid-sensor", qos: .userInteractive)
    @MainActor private var poller: Poller?
    @MainActor private var generation: UInt64 = 0

    @MainActor
    func start(onSample: @escaping (Result<LidSample, Error>) -> Void) {
        guard poller == nil else { return }
        generation &+= 1
        let currentGeneration = generation
        let poller = Poller(queue: queue) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration, self.poller != nil else { return }
                    onSample(result)
                }
            }
        }
        self.poller = poller
        queue.async { poller.start() }
    }

    @MainActor
    func stop() {
        generation &+= 1
        let previous = poller
        poller = nil
        queue.async { previous?.stop() }
    }

    static func readOnce() throws -> LidSample {
        let connection = try Connection()
        defer { connection.close() }
        return try connection.read()
    }

    static func decodeReport(_ bytes: [UInt8]) -> Double? {
        guard bytes.count >= 3, bytes[0] == 1 else { return nil }
        let degrees = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        guard degrees <= 180 else { return nil }
        return Double(degrees)
    }

    private enum SensorError: LocalizedError {
        case unavailable
        case io(String, IOReturn)
        case invalidReport

        var errorDescription: String? {
            switch self {
            case .unavailable: return "No compatible lid angle sensor is available."
            case let .io(operation, status): return "Lid sensor \(operation) failed (\(status))."
            case .invalidReport: return "The lid sensor returned an invalid angle report."
            }
        }
    }

    // A connection is confined to its caller's serial queue, including destruction.
    private final class Connection {
        private let manager: IOHIDManager
        private var device: IOHIDDevice?

        init() throws {
            manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            let matching: [String: Any] = [
                kIOHIDVendorIDKey: 0x05AC,
                kIOHIDDeviceUsagePageKey: 0x20,
                kIOHIDDeviceUsageKey: 0x8A
            ]
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
            let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard status == kIOReturnSuccess else { throw SensorError.io("discovery", status) }

            if let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
                for candidate in devices {
                    let opened = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
                    guard opened == kIOReturnSuccess else { continue }
                    device = candidate
                    // The HID usage is shared by other orientation devices. Check its report.
                    if (try? read()) != nil { return }
                    IOHIDDeviceClose(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
                    device = nil
                }
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw SensorError.unavailable
        }

        func read() throws -> LidSample {
            guard let device else { throw SensorError.unavailable }
            var bytes = [UInt8](repeating: 0, count: 64)
            var count = bytes.count
            let status = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &count)
            guard status == kIOReturnSuccess else { throw SensorError.io("read", status) }
            guard count >= 3, count <= bytes.count,
                  let degrees = LidAngleSensor.decodeReport(Array(bytes.prefix(count))) else {
                throw SensorError.invalidReport
            }
            return LidSample(degrees: degrees, timestamp: ProcessInfo.processInfo.systemUptime)
        }

        func close() {
            if let device {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
                self.device = nil
            }
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    // Only the reference crosses queues. Every mutable field and HID operation stays on queue.
    private final class Poller: @unchecked Sendable {
        private let queue: DispatchQueue
        private let deliver: (Result<LidSample, Error>) -> Void
        private var timer: DispatchSourceTimer?
        private var connection: Connection?
        private var retryAfter: TimeInterval = 0

        init(queue: DispatchQueue, deliver: @escaping (Result<LidSample, Error>) -> Void) {
            self.queue = queue
            self.deliver = deliver
        }

        func start() {
            dispatchPrecondition(condition: .onQueue(queue))
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }

        func stop() {
            dispatchPrecondition(condition: .onQueue(queue))
            timer?.cancel()
            timer = nil
            connection?.close()
            connection = nil
        }

        private func poll() {
            guard ProcessInfo.processInfo.systemUptime >= retryAfter else { return }
            do {
                if connection == nil { connection = try Connection() }
                guard let connection else { return }
                deliver(.success(try connection.read()))
            } catch {
                connection?.close()
                connection = nil
                retryAfter = ProcessInfo.processInfo.systemUptime + 0.5
                deliver(.failure(error))
            }
        }
    }
}
