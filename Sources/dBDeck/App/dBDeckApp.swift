import AppKit
import OSLog
import SwiftUI

enum MenuBarIcon {
    static let image: NSImage = {
        let image = Bundle.main.url(
            forResource: "dBDeckMenuBarIcon",
            withExtension: "svg"
        ).flatMap(NSImage.init(contentsOf:)) ?? NSImage(
            systemSymbolName: "slider.vertical.3",
            accessibilityDescription: String(localized: "dBDeck")
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppAudioStore(
        preferences: VolumePreferences(defaults: .dbdeck),
        playbackHistory: PlaybackHistoryStore(defaults: .dbdeck),
        performsInitialRefresh: false
    )

    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "App")
    private var mixerWindowController: NSWindowController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Menu bar agent launched")

#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "--verify-route") {
            let pidIndex = arguments.index(after: flagIndex)
            let pid = pidIndex < arguments.endIndex ? pid_t(arguments[pidIndex]) : nil
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let pid else {
                        throw AudioRouteVerificationError.invalidProcessID
                    }
                    try AudioRouteIntegrationVerifier().run(processID: pid)
                    print("Core Audio route integration verification passed")
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                } catch {
                    fputs("Core Audio route integration verification failed: \(error.localizedDescription)\n", stderr)
                    fflush(stderr)
                    exit(EXIT_FAILURE)
                }
            }
            return
        }
#endif

        statusItemController = StatusItemController(store: store)
        installQuitShortcut()

        // One run-loop turn later, so the menu bar item is on screen before the
        // first discovery pass runs.
        Task { @MainActor [store] in
            store.refresh()
        }
    }

    /// Gives the panel a Quit shortcut without giving the app a menu bar.
    ///
    /// An accessory app never displays its menu bar, but `NSApplication` still
    /// routes key equivalents through the main menu, so a menu that exists only
    /// to carry Command-Q stays invisible and still works.
    private func installQuitShortcut() {
        let quitItem = NSMenuItem(
            title: String(localized: "Quit"),
            action: #selector(quitFromShortcut),
            keyEquivalent: "q"
        )
        quitItem.target = self

        let applicationMenu = NSMenu()
        applicationMenu.addItem(quitItem)

        let applicationMenuItem = NSMenuItem()
        applicationMenuItem.submenu = applicationMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem)
        NSApp.mainMenu = mainMenu
    }

    /// Routed through the store so a keyboard quit tears routes down and flushes
    /// state exactly as the panel's own Quit button does.
    @objc private func quitFromShortcut() {
        store.quit()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMixerWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushPendingState()
    }

    private func showMixerWindow() {
        let controller: NSWindowController
        if let mixerWindowController {
            controller = mixerWindowController
        } else {
            let hostingController = NSHostingController(
                rootView: QuickMixerView(store: store)
            )
            let window = NSWindow(contentViewController: hostingController)
            window.title = String(localized: "dBDeck")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 380, height: 430))
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.center()

            controller = NSWindowController(window: window)
            mixerWindowController = controller
        }

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        logger.info("Mixer recovery window shown after app reopen")
    }
}
