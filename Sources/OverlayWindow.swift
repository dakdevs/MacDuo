import AppKit
import MetalKit

@MainActor final class OverlayWindow: NSPanel {
    let renderer: PlaneRenderer
    private let metalView: MTKView

    init(screen: NSScreen) throws {
        let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        metalView = view
        renderer = try PlaneRenderer(view: view)
        // The display link is the only source of visible overlay draws.
        view.enableSetNeedsDisplay = false
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        contentView = view
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        alphaValue = 0
        // Cover the menu bar and Dock as part of the same frozen desktop plane.
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func drawFrame() { metalView.draw() }

    func hideAndDiscard() {
        orderOut(nil)
        alphaValue = 0
        renderer.clearFrame()
    }
}
