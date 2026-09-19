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

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Menu bar template icon configured")

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

        // One run-loop turn later, so the menu bar item is on screen before the
        // first discovery pass runs.
        Task { @MainActor [store] in
            store.refresh()
        }
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

/// A menu bar agent: no Dock icon and no main window, with the mixer presented
/// from the status item.
///
/// `applicationShouldHandleReopen` opens the mixer in a window as well, which is
/// the way back in if the menu bar is too full to show the status item.
@main
struct dBDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var isMenuBarExtraInserted = true

    var body: some Scene {
        MenuBarExtra(isInserted: $isMenuBarExtraInserted) {
            QuickMixerView(store: appDelegate.store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("dBDeck")
        }
        .menuBarExtraStyle(.window)
    }
}
