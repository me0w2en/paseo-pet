import AppKit
import Combine
import SwiftUI

/// Borderless, transparent, always-on-top panel that never steals focus from the app the user is in.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetWindowController {
    private static let anchorKey = "petAnchor"
    private static let margin: CGFloat = 24

    let panel: PetPanel
    private let model: PetModel
    private var hosting: NSHostingView<PetRootView>!
    private var cancellables = Set<AnyCancellable>()
    /// Bottom-right corner of the pet in screen coordinates; bubbles grow up and to the left of it.
    private var anchor: NSPoint
    private var dragStart: (mouse: NSPoint, anchor: NSPoint)?

    var visible = true {
        didSet { updateVisibility() }
    }

    init(model: PetModel) {
        self.model = model
        panel = PetPanel(
            contentRect: NSRect(x: 0, y: 0, width: 110, height: 110),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        if let saved = UserDefaults.standard.string(forKey: Self.anchorKey) {
            anchor = NSPointFromString(saved)
        } else {
            let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            anchor = NSPoint(x: frame.maxX - Self.margin, y: frame.minY + Self.margin)
        }

        hosting = NSHostingView(rootView: PetRootView(
            model: model,
            onDrag: { [weak self] _ in self?.drag() },
            onDragEnd: { [weak self] in self?.endDrag() }
        ))
        panel.contentView = hosting

        // NSHostingView resizes the window itself and keeps the bottom-left corner fixed;
        // pin the bottom-right corner instead so bubbles grow toward the screen.
        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .sink { [weak self] _ in self?.pinToAnchor() }
            .store(in: &cancellables)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)

        // Monitors come and go; a position saved on a display that is gone would leave the pet off screen.
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.clampToScreen() }
            .store(in: &cancellables)

        clampToScreen()
        layout()
        updateVisibility()
    }

    private func layout() {
        panel.setContentSize(hosting.fittingSize)
        pinToAnchor()
    }

    private func pinToAnchor() {
        let origin = NSPoint(x: anchor.x - panel.frame.width, y: anchor.y)
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
        }
    }

    private func updateVisibility() {
        if visible && !model.quiet {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func drag() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, anchor)
        }
        guard let start = dragStart else { return }
        anchor = NSPoint(x: start.anchor.x + mouse.x - start.mouse.x, y: start.anchor.y + mouse.y - start.mouse.y)
        pinToAnchor()
    }

    private func endDrag() {
        dragStart = nil
        clampToScreen()
        UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: Self.anchorKey)
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.anchorKey)
        let frame = NSScreen.main?.visibleFrame ?? .zero
        anchor = NSPoint(x: frame.maxX - Self.margin, y: frame.minY + Self.margin)
        layout()
    }

    private func clampToScreen() {
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.contains(where: { $0.insetBy(dx: -40, dy: -40).contains(anchor) }),
              let frame = NSScreen.main?.visibleFrame else { return }
        anchor = NSPoint(
            x: min(max(anchor.x, frame.minX + 100), frame.maxX),
            y: min(max(anchor.y, frame.minY), frame.maxY - 100)
        )
        layout()
    }
}
