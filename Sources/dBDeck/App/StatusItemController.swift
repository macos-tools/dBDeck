import AppKit
import SwiftUI

/// Owns the menu bar item and the panel it presents.
///
/// The panel is an `NSPopover` rather than a SwiftUI `MenuBarExtra` window
/// because the material is the point: a popover is drawn with the system's
/// popover material, the same treatment Control Center and other menu bar
/// panels get. SwiftUI's window background only offers thickness tiers
/// (`.ultraThin` through `.ultraThick`), none of which reproduce it.
///
/// Only the container is AppKit. The panel's contents are the same
/// `QuickMixerView` the rest of the app uses, hosted unchanged.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(store: AppAudioStore) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        super.init()

        // `.transient` closes the panel when the user clicks away or switches
        // app, which is what every other menu bar panel does.
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 430)
        popover.contentViewController = Self.makeContentController(store: store)

        guard let button = statusItem.button else { return }
        let image = MenuBarIcon.image.copy() as? NSImage ?? MenuBarIcon.image
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = String(localized: "dBDeck")
        button.target = self
        button.action = #selector(togglePanel)
    }

    /// The panel's background.
    ///
    /// A popover draws itself with the popover material, which is a notably grey
    /// one: over a white backdrop it lands around 229 where the menu bar panels
    /// people compare this against sit near 254. The header-view material reads
    /// as the white those panels are, and still tracks what is behind it rather
    /// than being a flat fill.
    private static let panelMaterial: NSVisualEffectView.Material = .headerView

    private static func makeContentController(store: AppAudioStore) -> NSViewController {
        let background = NSVisualEffectView(
            frame: NSRect(x: 0, y: 0, width: 380, height: 430)
        )
        background.material = panelMaterial
        background.blendingMode = .behindWindow
        background.state = .active

        // Added as a child controller rather than a bare hosting view, so the
        // SwiftUI content stays in the responder chain. Its view is opaque by
        // default and would paint over the material, so it gets no background
        // of its own.
        let content = NSHostingController(rootView: QuickMixerView(store: store))
        content.view.frame = background.bounds
        content.view.autoresizingMask = [.width, .height]
        content.view.wantsLayer = true
        content.view.layer?.backgroundColor = NSColor.clear.cgColor

        let controller = NSViewController()
        controller.view = background
        controller.addChild(content)
        background.addSubview(content.view)
        return controller
    }

    /// Opens the panel, for callers that need it shown rather than toggled.
    func showPanel() {
        guard !popover.isShown else { return }
        presentPanel()
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            presentPanel()
        }
    }

    private func presentPanel() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
