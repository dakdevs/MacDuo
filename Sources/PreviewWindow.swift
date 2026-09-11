import AppKit
import MetalKit
import QuartzCore

@MainActor final class PreviewWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onCalibration: ((ViewCalibration) -> Void)?
    var onPermission: (() -> Void)?
    var onEnable: (() -> Void)?
    var sampleSmoothedAngle: (() -> Double?)?
    private var followDisplayLink: CADisplayLink?
    private let liveLabel = NSTextField(labelWithString: "Reading lid sensor…")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let angleLabel = NSTextField(labelWithString: "65°")
    private let permissionButton = NSButton(title: "Allow Screen Recording…", target: nil, action: nil)
    private let enableButton = NSButton(title: "Enable effect", target: nil, action: nil)
    private let followButton = NSButton(checkboxWithTitle: "Follow the actual lid", target: nil, action: nil)
    private let angleSlider = NSSlider(value: 65, minValue: 0, maxValue: 110, target: nil, action: nil)
    private var valueLabels: [Int: NSTextField] = [:]
    private var sliders: [Int: NSSlider] = [:]
    private var calibration: ViewCalibration
    private var renderer: PlaneRenderer!

    init(calibration: ViewCalibration) throws {
        self.calibration = calibration
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 770),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "MacDuo"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "An upright desktop. A moving lid.")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        root.addArrangedSubview(title)
        let detail = NSTextField(wrappingLabelWithString: "Prepares at 92° and eases into the effect below 90°. The default view is straight on. Frost builds from a clear lower screen to a blurred top; adjust the eye position to match your view.")
        detail.textColor = .secondaryLabelColor
        root.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true

        let metalView = MTKView()
        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.wantsLayer = true
        metalView.layer?.cornerRadius = 10
        metalView.layer?.masksToBounds = true
        root.addArrangedSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48),
            metalView.heightAnchor.constraint(equalToConstant: 350)
        ])
        renderer = try PlaneRenderer(view: metalView)
        renderer.calibration = calibration
        renderer.degrees = 65
        try renderer.useTestPattern()
        renderer.onFailure = { [weak self] message in self?.statusLabel.stringValue = message }

        angleSlider.target = self
        angleSlider.action = #selector(angleChanged)
        angleSlider.widthAnchor.constraint(equalToConstant: 440).isActive = true
        angleLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let angleRow = NSStackView(views: [NSTextField(labelWithString: "Preview angle"), angleSlider, angleLabel])
        angleRow.spacing = 14
        root.addArrangedSubview(angleRow)
        followButton.target = self
        followButton.action = #selector(followChanged)
        liveLabel.textColor = .secondaryLabelColor
        let liveRow = NSStackView(views: [followButton, liveLabel])
        liveRow.spacing = 28
        root.addArrangedSubview(liveRow)

        addCalibrationRow(to: root, title: "Eye distance from hinge", tag: 0, value: Double(calibration.distanceCM), min: 30, max: 120)
        addCalibrationRow(to: root, title: "Eye height above hinge", tag: 1, value: Double(calibration.heightCM), min: 0, max: 70)
        addCalibrationRow(to: root, title: "Frost strength", tag: 2, value: Double(calibration.frost), min: 0, max: 2)
        addCalibrationRow(to: root, title: "Perspective strength", tag: 3, value: Double(calibration.perspective), min: 0, max: 1)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        root.addArrangedSubview(spacer)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        root.addArrangedSubview(statusLabel)
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        enableButton.target = self
        enableButton.action = #selector(enableEffect)
        enableButton.bezelStyle = .rounded
        enableButton.keyEquivalent = "\r"
        let reset = NSButton(title: "Reset to straight-on", target: self, action: #selector(resetView))
        let actions = NSStackView(views: [reset, permissionButton, enableButton])
        actions.spacing = 12
        root.addArrangedSubview(actions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        followChanged()
    }

    func update(angle: Double?, status: String, permission: Bool) {
        liveLabel.stringValue = angle.map { "Lid now: \(Int($0.rounded()))°" } ?? "Sensor unavailable"
        statusLabel.stringValue = status
        permissionButton.isHidden = permission
        enableButton.isEnabled = permission && angle != nil
    }

    func windowWillClose(_ notification: Notification) {
        followDisplayLink?.invalidate()
        followDisplayLink = nil
        onClose?()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if followButton.state == .on { followChanged() }
    }

    private func addCalibrationRow(to root: NSStackView, title: String, tag: Int, value: Double, min: Double, max: Double) {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 175).isActive = true
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(calibrationChanged(_:)))
        slider.tag = tag
        slider.widthAnchor.constraint(equalToConstant: 355).isActive = true
        let valueLabel = NSTextField(labelWithString: valueText(tag, value))
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let row = NSStackView(views: [label, slider, valueLabel])
        row.spacing = 16
        root.addArrangedSubview(row)
        sliders[tag] = slider
        valueLabels[tag] = valueLabel
    }

    private func valueText(_ tag: Int, _ value: Double) -> String {
        if tag == 2 { return String(format: "%.1f×", value) }
        if tag == 3 { return "\(Int((value * 100).rounded()))%" }
        return "\(Int(value.rounded())) cm"
    }

    @objc private func angleChanged() {
        renderer.degrees = angleSlider.floatValue
        angleLabel.stringValue = "\(Int(angleSlider.doubleValue.rounded()))°"
    }

    @objc private func followChanged() {
        followDisplayLink?.invalidate()
        followDisplayLink = nil
        angleSlider.isEnabled = followButton.state != .on
        if followButton.state == .off { angleChanged(); return }
        guard let window, window.isVisible else { return }
        let link = window.displayLink(target: self, selector: #selector(followDisplayLinkDidFire(_:)))
        let refreshRate = Float(min(120, window.screen?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: refreshRate, maximum: refreshRate, preferred: refreshRate)
        followDisplayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func followDisplayLinkDidFire(_ link: CADisplayLink) {
        guard link === followDisplayLink, followButton.state == .on, window?.isVisible == true else { return }
        renderLiveAngle()
    }

    private func renderLiveAngle() {
        guard let angle = sampleSmoothedAngle?() else { return }
        angleSlider.doubleValue = angle
        renderer.degrees = Float(angle)
        angleLabel.stringValue = "\(Int(angle.rounded()))°"
    }

    @objc private func calibrationChanged(_ sender: NSSlider) {
        switch sender.tag {
        case 0: calibration.distanceCM = sender.floatValue
        case 1: calibration.heightCM = sender.floatValue
        case 2: calibration.frost = sender.floatValue
        default: calibration.perspective = sender.floatValue
        }
        valueLabels[sender.tag]?.stringValue = valueText(sender.tag, sender.doubleValue)
        renderer.calibration = calibration
        onCalibration?(calibration)
    }

    @objc private func resetView() {
        let screenHeight = calibration.screenHeightCM
        calibration = ViewCalibration(screenHeightCM: screenHeight)
        for (tag, value) in [(0, calibration.distanceCM), (1, calibration.heightCM), (2, calibration.frost), (3, calibration.perspective)] {
            sliders[tag]?.floatValue = value
            valueLabels[tag]?.stringValue = valueText(tag, Double(value))
        }
        renderer.calibration = calibration
        onCalibration?(calibration)
    }

    @objc private func requestPermission() { onPermission?() }
    @objc private func enableEffect() { onEnable?() }
}
