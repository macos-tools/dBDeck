import AppKit
import OSLog
import SwiftUI

@MainActor
final class MixerPanelController: NSObject {
    private let logger = Logger(subsystem: "com.dbdeck.app", category: "MixerPanel")
    private let panel: NSPanel

    init(store: AppAudioStore) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "dBDeck"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentViewController = NSHostingController(
            rootView: QuickMixerView(store: store)
        )
        panel.setContentSize(NSSize(width: 380, height: 430))
        logger.info("Quick mixer panel installed")
    }

    func show() {
        positionNearControlCenter()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        logger.info("Quick mixer panel shown")
    }

    var isVisible: Bool {
        panel.isVisible
    }

    private func positionNearControlCenter() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }

        let origin = NSPoint(
            x: visibleFrame.maxX - panel.frame.width - 12,
            y: visibleFrame.maxY - panel.frame.height - 12
        )
        panel.setFrameOrigin(origin)
    }
}
