import AppKit
import CoreGraphics
import QuartzCore

@MainActor final class AppController: NSObject, NSApplicationDelegate {
    private let sensor = LidAngleSensor()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let enabledMenu = NSMenuItem(title: "Enable effect", action: nil, keyEquivalent: "")
    private let permissionMenu = NSMenuItem(title: "Allow Screen Recording…", action: nil, keyEquivalent: "")
    private let pauseHint = NSMenuItem(title: "Pause shortcut: ⌃⌥⌘L", action: nil, keyEquivalent: "")
    private var hotKey: PauseHotKey?
    private var timer: Timer?
    private var displayLink: DisplayClock?
    private var framePacing = FramePacing()
    private var motion = LidMotion()
    private var transition = EffectTransition()
    private var overlay: OverlayWindow?
    private var preview: PreviewWindow?
    private var snapshotTask: Task<Void, Never>?
    private var snapshotAttempted = false
    private var generation = 0
    private var latestSample: LidSample?
    private var sensorError: String?
    private var captureError: String?
    private var snapshotStarted: TimeInterval = 0
    private var snapshotRequestedAngle: Double?
    private var preparationMilliseconds: Double?
    private var entryFrames: [[String: Double]] = []
    private var permission = false
    private var enabled = true
    private enum SuspensionReason: Hashable { case sleep, displaySleep, session, lock }
    private var suspensionReasons = Set<SuspensionReason>()
    private var suspended: Bool { !suspensionReasons.isEmpty }
    private var previewOpen = false
    private var screen: NSScreen?
    private var calibration = ViewCalibration()
    private var lastUIUpdate: TimeInterval = 0
    private var screenshotsTaken = 0
    private var lastDiagnosticWrite: TimeInterval = 0
    private var demoStart: TimeInterval?
    private var diagnosticPath: String?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--diagnostics"), args.indices.contains(index + 1) {
            diagnosticPath = args[index + 1]
        }
        permission = CGPreflightScreenCaptureAccess()
        enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
        refreshScreen()
        loadCalibration()
        buildMenu()
        do { try prepareGraphics() }
        catch { captureError = "Could not prepare the graphics effect: \(error.localizedDescription)" }
        hotKey = PauseHotKey { [weak self] in self?.setEnabled(false) }
        observeLifecycle()
        sensor.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sample):
                self.latestSample = sample
                self.motion.observe(degrees: sample.degrees, at: sample.timestamp)
                self.sensorError = nil
            case .failure(let error):
                self.latestSample = nil
                self.motion.reset()
                self.sensorError = error.localizedDescription
                self.stopCapture()
            }
            self.evaluate()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)

        if args.contains("--preview") || !permission {
            showPreview()
        } else if args.contains("--demo-once") {
            startDemo()
        }
        updateUI()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        overlay?.orderOut(nil)
        sensor.stop()
        timer?.invalidate()
        displayLink?.invalidate()
        stopCapture()
        writeDiagnostic(force: true)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private var angle: Double? {
        guard let sample = latestSample, now - sample.timestamp < 0.5 else { return nil }
        return sample.degrees
    }

    private var effectAngle: Double? {
        effectAngle(at: now)
    }

    private func effectAngle(at timestamp: TimeInterval) -> Double? {
        if let start = demoStart {
            let elapsed = timestamp - start
            if elapsed < 8 {
                // One reversible eight-second gesture, then return to measured angle.
                return 94 - 56 * pow(sin(Double.pi * elapsed / 8), 2)
            }
        }
        return angle
    }

    private var status: String {
        if suspended { return "Paused while the display is asleep or locked." }
        if let sensorError { return sensorError }
        if angle == nil { return "Waiting for the lid-angle sensor…" }
        if !permission { return "macOS requires Screen Recording permission for a screenshot. MacDuo takes one image per gesture, keeps it in memory, and records no video." }
        if !enabled { return "Paused. Enable the effect from the menu bar." }
        if let captureError { return captureError }
        if previewOpen { return "Previewing a sample desktop. Close this window to use your desktop snapshot. Pause any time with ⌃⌥⌘L." }
        if screen == nil { return "Waiting for the built-in display." }
        if demoStart != nil { return "Running an eight-second desktop demo. ⌃⌥⌘L pauses immediately." }
        if overlay?.isVisible == true { return "Holding the desktop upright. Open to 90° to restore the normal view." }
        if snapshotTask != nil { return "Preparing the desktop snapshot before 90°…" }
        if overlay?.renderer.isReadyForPresentation == true { return "Snapshot ready. The effect starts below 90°." }
        return "Ready. Prepares at 92°; the effect starts below 90°. Pause any time with ⌃⌥⌘L."
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "MacDuo")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let menu = NSMenu()
        statusMenu.isEnabled = false
        menu.addItem(statusMenu)
        menu.addItem(.separator())
        enabledMenu.target = self
        enabledMenu.action = #selector(toggleEnabled)
        menu.addItem(enabledMenu)
        let previewItem = NSMenuItem(title: "Preview & calibration…", action: #selector(showPreview), keyEquivalent: "")
        previewItem.target = self
        menu.addItem(previewItem)
        let demoItem = NSMenuItem(title: "Try desktop effect for 8 seconds", action: #selector(startDemo), keyEquivalent: "")
        demoItem.target = self
        menu.addItem(demoItem)
        permissionMenu.target = self
        permissionMenu.action = #selector(requestPermission)
        menu.addItem(permissionMenu)
        menu.addItem(.separator())
        pauseHint.isEnabled = false
        menu.addItem(pauseHint)
        let quit = NSMenuItem(title: "Quit MacDuo", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func tick() {
        if now - lastUIUpdate > 0.5 {
            lastUIUpdate = now
            // Check only the permission we need; never change privacy settings ourselves.
            permission = CGPreflightScreenCaptureAccess()
            updateUI()
        }
        if let start = demoStart, now - start >= 8 {
            demoStart = nil
            stopCapture()
        }
        if snapshotTask != nil, now - snapshotStarted > 3 {
            captureFailed("The screenshot took too long. Open the lid to 94° to try again.")
        }
        evaluate()
        writeDiagnostic()
    }

    private func evaluate() {
        guard enabled, !suspended, !previewOpen, permission, screen != nil, angle != nil,
              let degrees = effectAngle else {
            stopCapture()
            return
        }
        // Keep one prepared image through the threshold band so one-degree sensor
        // steps do not repeatedly capture or rebuild the blur pyramid.
        if degrees >= 94 {
            stopCapture()
            return
        }
        if degrees <= 92, !snapshotAttempted { beginCapture() }
        updateOverlay()
    }

    private func prepareGraphics() throws {
        guard overlay == nil, let screen else { return }
        overlay = try OverlayWindow(screen: screen)
        overlay?.renderer.onFailure = { [weak self] error in self?.captureFailed(error) }
        if diagnosticPath != nil {
            overlay?.renderer.onFramePresented = { [weak self] timestamp, gpuMilliseconds in
                self?.framePacing.recordPresentation(at: timestamp, gpuDurationMilliseconds: gpuMilliseconds)
            }
        }
    }

    private func beginCapture() {
        guard !snapshotAttempted, let screen, let displayID = Self.displayID(screen) else { return }
        snapshotAttempted = true
        do {
            try prepareGraphics()
        } catch {
            captureFailed("Could not start the graphics effect: \(error.localizedDescription)")
            return
        }
        generation += 1
        let current = generation
        snapshotStarted = now
        snapshotRequestedAngle = effectAngle
        preparationMilliseconds = nil
        captureError = nil
        snapshotTask = Task { [weak self] in
            do {
                let buffer = try await DesktopSnapshot.take(displayID: displayID)
                guard let self, self.generation == current, !Task.isCancelled,
                      self.screen.flatMap(Self.displayID) == displayID,
                      CGDisplayIsOnline(displayID) != 0 else { return }
                guard let renderer = self.overlay?.renderer else { return }
                renderer.calibration = self.calibration
                renderer.degrees = 90
                try renderer.setFrame(buffer)
                self.screenshotsTaken += 1
                try await renderer.prepareForPresentation()
                guard self.generation == current, !Task.isCancelled else { return }
                self.preparationMilliseconds = (self.now - self.snapshotStarted) * 1000
                self.snapshotTask = nil
                self.updateOverlay()
            } catch {
                guard let self, self.generation == current else { return }
                self.captureFailed(error.localizedDescription)
            }
        }
    }

    private func updateOverlay(at presentationTime: TimeInterval? = nil) {
        guard let overlay else { return }
        guard enabled, !suspended, !previewOpen, permission, angle != nil, let screen,
              let degrees = effectAngle, degrees < 90, snapshotTask == nil,
              overlay.renderer.isReadyForPresentation else {
            overlay.orderOut(nil)
            overlay.alphaValue = 0
            transition.reset()
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        if displayLink == nil {
            guard let displayID = Self.displayID(screen) else {
                captureFailed("The built-in display is unavailable.")
                return
            }
            let refreshRate = min(120, max(1, screen.maximumFramesPerSecond))
            framePacing.reset(requestedFramesPerSecond: refreshRate)
            overlay.alphaValue = 0
            overlay.orderFrontRegardless()
            do {
                displayLink = try DisplayClock(displayID: displayID) { [weak self] target in
                    self?.displayFrame(at: target)
                }
            } catch {
                captureFailed(error.localizedDescription)
                return
            }
        }
        // Sensor and housekeeping callbacks change eligibility only. A display
        // callback owns each angle sample and explicit Metal draw.
        guard let timestamp = presentationTime else { return }
        let projected = demoStart == nil ? (motion.value(at: timestamp) ?? degrees)
                                         : (effectAngle(at: timestamp) ?? degrees)
        let firstFrame = transition.startedAt == nil
        let frame = transition.frame(targetDegrees: projected, at: timestamp)
        overlay.renderer.degrees = Float(frame.degrees)
        if overlay.alphaValue != frame.opacity { overlay.alphaValue = frame.opacity }
        if firstFrame {
            entryFrames.removeAll(keepingCapacity: true)
        }
        if diagnosticPath != nil, let start = transition.startedAt,
           timestamp - start <= 0.3, entryFrames.count < 100 {
            entryFrames.append(["elapsed": timestamp - start, "measured": degrees,
                                "sampled": projected,
                                "rendered": frame.degrees, "opacity": frame.opacity])
        }
        overlay.drawFrame()
    }

    private func displayFrame(at target: TimeInterval) {
        guard displayLink != nil else { return }
        if diagnosticPath != nil { framePacing.recordDisplayTarget(target) }
        // Convert the display's media clock to the sensor's uptime clock and
        // predict only to this frame's deadline, within the existing motion bound.
        let lead = min(0.025, max(0, target - CACurrentMediaTime()))
        updateOverlay(at: now + lead)
    }

    private func stopCapture() {
        transition.reset()
        displayLink?.invalidate()
        displayLink = nil
        guard snapshotAttempted || snapshotTask != nil || overlay?.renderer.hasFrame == true else { return }
        overlay?.hideAndDiscard()
        generation += 1
        snapshotTask?.cancel()
        snapshotTask = nil
        snapshotAttempted = false
        captureError = nil
    }

    private func captureFailed(_ message: String) {
        transition.reset()
        captureError = message
        generation += 1
        snapshotTask?.cancel()
        snapshotTask = nil
        overlay?.hideAndDiscard()
        displayLink?.invalidate()
        displayLink = nil
        // Keep the attempted flag: a failed gesture must not become repeated screenshots.
        updateUI()
    }

    private func updateUI() {
        statusItem?.button?.title = angle.map { " \(Int($0.rounded()))°" } ?? " —°"
        statusItem?.button?.appearsDisabled = !enabled || suspended
        statusItem?.button?.toolTip = "MacDuo. \(status)"
        statusMenu.title = status.count > 80 ? String(status.prefix(77)) + "…" : status
        enabledMenu.state = enabled ? .on : .off
        permissionMenu.isHidden = permission
        if let code = hotKey?.registrationStatus, code != 0 {
            pauseHint.title = "Pause shortcut unavailable (\(code)); open lid to 90°"
        } else { pauseHint.title = "Pause shortcut: ⌃⌥⌘L" }
        preview?.update(angle: angle, status: status, permission: permission)
    }

    private func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "enabled")
        demoStart = nil
        if !value { stopCapture() }
        evaluate()
        updateUI()
    }

    @objc private func toggleEnabled() { setEnabled(!enabled) }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func showPreview() {
        previewOpen = true
        demoStart = nil
        stopCapture()
        do {
            if preview == nil {
                let panel = try PreviewWindow(calibration: calibration)
                panel.sampleSmoothedAngle = { [weak self] in
                    guard let self else { return nil }
                    return self.motion.value(at: self.now)
                }
                panel.onClose = { [weak self] in
                    self?.previewOpen = false
                    self?.evaluate()
                    self?.updateUI()
                }
                panel.onCalibration = { [weak self] value in
                    self?.calibration = value
                    self?.saveCalibration()
                }
                panel.onPermission = { [weak self] in self?.requestPermission() }
                panel.onEnable = { [weak self] in
                    guard let self else { return }
                    self.preview?.close()
                    self.setEnabled(true)
                }
                preview = panel
            }
            preview?.present()
            updateUI()
        } catch {
            previewOpen = false
            captureFailed("Could not open the preview: \(error.localizedDescription)")
        }
    }

    @objc private func startDemo() {
        guard permission else { showPreview(); return }
        preview?.close()
        setEnabled(true)
        demoStart = now
        evaluate()
    }

    @objc private func requestPermission() {
        stopCapture()
        NSApp.activate(ignoringOtherApps: true)
        let granted = CGRequestScreenCaptureAccess()
        permission = granted || CGPreflightScreenCaptureAccess()
        if !permission, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        updateUI()
    }

    private func refreshScreen() {
        screen = NSScreen.screens.first { screen in
            Self.displayID(screen).map { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsOnline($0) != 0 } ?? false
        }
        if let screen, let id = Self.displayID(screen) {
            let centimeters = Float(CGDisplayScreenSize(id).height / 10)
            if centimeters.isFinite, (10...40).contains(centimeters) {
                calibration.screenHeightCM = centimeters
                if UserDefaults.standard.object(forKey: "eyeHeight") == nil {
                    calibration.heightCM = centimeters / 2
                }
            }
        }
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        let sleepEvents: [(Notification.Name, SuspensionReason)] = [
            (NSWorkspace.willSleepNotification, .sleep),
            (NSWorkspace.screensDidSleepNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, .session)
        ]
        for (name, reason) in sleepEvents {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(reason) }
            })
        }
        let wakeEvents: [(Notification.Name, SuspensionReason)] = [
            (NSWorkspace.didWakeNotification, .sleep),
            (NSWorkspace.screensDidWakeNotification, .displaySleep),
            (NSWorkspace.sessionDidBecomeActiveNotification, .session)
        ]
        for (name, reason) in wakeEvents {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(reason) }
            })
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // macOS's distributed lock notifications complement workspace sleep/session events.
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(.lock) }
        })
        distributedObservers.append(distributed.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume(.lock) }
        })
    }

    private func suspend(_ reason: SuspensionReason) {
        suspensionReasons.insert(reason)
        demoStart = nil
        latestSample = nil
        motion.reset()
        stopCapture()
        sensor.stop()
        updateUI()
    }

    private func resume(_ reason: SuspensionReason) {
        suspensionReasons.remove(reason)
        guard !suspended else { updateUI(); return }
        latestSample = nil
        motion.reset()
        captureError = nil
        refreshScreen()
        sensor.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let sample):
                self.latestSample = sample
                self.motion.observe(degrees: sample.degrees, at: sample.timestamp)
                self.sensorError = nil
            case .failure(let error):
                self.latestSample = nil
                self.motion.reset()
                self.sensorError = error.localizedDescription
                self.stopCapture()
            }
            self.evaluate()
        }
    }

    @objc private func displayChanged() {
        stopCapture()
        overlay?.close()
        overlay = nil
        refreshScreen()
        do { try prepareGraphics() }
        catch { captureError = "Could not prepare the graphics effect: \(error.localizedDescription)" }
        evaluate()
    }

    private func loadCalibration() {
        let defaults = UserDefaults.standard
        let baseline = ViewCalibration(screenHeightCM: calibration.screenHeightCM)
        calibration = baseline
        if defaults.object(forKey: "eyeDistance") != nil {
            calibration.distanceCM = valid(defaults.float(forKey: "eyeDistance"), range: 30...120, fallback: baseline.distanceCM)
        }
        if defaults.object(forKey: "eyeHeight") != nil {
            calibration.heightCM = valid(defaults.float(forKey: "eyeHeight"), range: 0...70, fallback: baseline.heightCM)
        }
        if defaults.object(forKey: "frost") != nil {
            calibration.frost = valid(defaults.float(forKey: "frost"), range: 0...2, fallback: baseline.frost)
        }
        if defaults.object(forKey: "perspective") != nil {
            calibration.perspective = valid(defaults.float(forKey: "perspective"), range: 0...1, fallback: baseline.perspective)
        }
    }

    private func valid(_ value: Float, range: ClosedRange<Float>, fallback: Float) -> Float {
        value.isFinite && range.contains(value) ? value : fallback
    }

    private func saveCalibration() {
        UserDefaults.standard.set(calibration.distanceCM, forKey: "eyeDistance")
        UserDefaults.standard.set(calibration.heightCM, forKey: "eyeHeight")
        UserDefaults.standard.set(calibration.frost, forKey: "frost")
        UserDefaults.standard.set(calibration.perspective, forKey: "perspective")
    }

    private func writeDiagnostic(force: Bool = false) {
        guard let diagnosticPath, force || now - lastDiagnosticWrite >= 1 else { return }
        lastDiagnosticWrite = now
        let values: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
            "eyeDistanceCM": calibration.distanceCM,
            "eyeHeightCM": calibration.heightCM,
            "screenHeightCM": calibration.screenHeightCM,
            "perspectiveStrength": calibration.perspective,
            "maximumFramesPerSecond": screen?.maximumFramesPerSecond ?? 0,
            "framePacing": framePacing.diagnostics,
            "measuredAngle": angle as Any? ?? NSNull(),
            "renderAngle": effectAngle as Any? ?? NSNull(),
            "smoothedAngle": motion.value(at: now) as Any? ?? NSNull(),
            "overlayWindowLevel": overlay?.level.rawValue as Any? ?? NSNull(),
            "hotKeyRegistrationStatus": hotKey?.registrationStatus as Any? ?? NSNull(),
            "rendererAngle": overlay?.renderer.degrees as Any? ?? NSNull(),
            "screenRecordingAllowed": permission,
            "enabled": enabled, "suspended": suspended, "previewOpen": previewOpen,
            "captureMode": "singleScreenshot",
            "snapshotInFlight": snapshotTask != nil, "screenshotsTaken": screenshotsTaken,
            "snapshotRequestedAngle": snapshotRequestedAngle as Any? ?? NSNull(),
            "preparationMilliseconds": preparationMilliseconds as Any? ?? NSNull(),
            "preparedForPresentation": overlay?.renderer.isReadyForPresentation ?? false,
            "overlayOpacity": overlay?.alphaValue as Any? ?? NSNull(),
            "entryFrames": entryFrames,
            "overlayVisible": overlay?.isVisible ?? false,
            "hasFrame": overlay?.renderer.hasFrame ?? false,
            "builtInDisplayID": screen.flatMap(Self.displayID) as Any? ?? NSNull(),
            "status": status
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: diagnosticPath), options: .atomic)
        } catch { fputs("Diagnostic write failed: \(error)\n", stderr) }
    }
}

@main struct MacDuoMain {
    @MainActor static func main() {
        if ProcessInfo.processInfo.arguments.contains("--probe") {
            do {
                let sample = try LidAngleSensor.readOnce()
                print("Lid angle: \(Int(sample.degrees))°")
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}
