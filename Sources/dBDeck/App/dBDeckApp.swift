import AppKit
import OSLog
import SwiftUI

enum MenuBarIcon {
    private static let resolved: (image: NSImage, loadedFromBundle: Bool) = {
        if let url = Bundle.main.url(
            forResource: "dBDeckMenuBarIcon",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            return (image, true)
        }

        let fallback = NSImage(
            systemSymbolName: "speaker.wave.2.fill",
            accessibilityDescription: "dBDeck"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return (fallback, false)
    }()

    static var image: NSImage { resolved.image }
    static var loadedFromBundle: Bool { resolved.loadedFromBundle }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppAudioStore()

    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "App")
    private var mixerWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("dBDeck menu bar service")
        ProcessInfo.processInfo.disableSuddenTermination()

        if MenuBarIcon.loadedFromBundle {
            logger.info("Menu bar template icon loaded from bundled SVG")
        } else {
            logger.error("Menu bar template icon missing; using system fallback")
        }

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
            window.title = "dBDeck"
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

@main
struct dBDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("menuBarExtraInserted") private var isMenuBarExtraInserted = true

    var body: some Scene {
        MenuBarExtra(isInserted: $isMenuBarExtraInserted) {
            QuickMixerView(store: appDelegate.store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityLabel("dBDeck")
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
