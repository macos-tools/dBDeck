import AppKit
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    init(store: AppAudioStore) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "speaker.wave.2",
                accessibilityDescription: "dBDeck"
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = "dBDeck · 音枢"
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("Open dBDeck")
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: 420)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarContentView(store: store)
        )
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc
    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }

        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
