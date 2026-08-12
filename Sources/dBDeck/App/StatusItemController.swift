import AppKit
import OSLog
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let logger = Logger(subsystem: "com.dbdeck.app", category: "MenuBar")
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(store: AppAudioStore) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.autosaveName = "dBDeckStatusItem"
        statusItem.isVisible = true

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "speaker.wave.2",
                accessibilityDescription: "dBDeck"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "dBDeck"
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Open dBDeck")
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 430)
        popover.contentViewController = NSHostingController(
            rootView: QuickMixerView(store: store)
        )
        logger.info("Menu bar status item installed")
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc
    func showPopover() {
        guard let button = statusItem.button else {
            logger.error("Unable to show popover because status item button is unavailable")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        logger.info("Popover shown")
    }

    var isPopoverShown: Bool {
        popover.isShown
    }

#if DEBUG
    var isStatusItemActuallyVisible: Bool {
        guard statusItem.isVisible,
              let button = statusItem.button,
              !button.isHiddenOrHasHiddenAncestor,
              let window = button.window,
              window.isVisible
        else {
            return false
        }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    func performStatusItemClickForVerification() {
        statusItem.button?.performClick(nil)
    }
#endif

    @objc
    private func togglePopover() {
        logger.info("Menu bar button activated")
        if popover.isShown {
            popover.performClose(nil)
            logger.info("Popover closed")
            return
        }
        showPopover()
    }
}
