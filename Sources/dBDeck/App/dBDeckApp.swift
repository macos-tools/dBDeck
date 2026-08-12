import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppAudioStore?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("dBDeck menu bar service")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.accessory)

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

        let store = AppAudioStore()
        self.store = store
        statusItemController = StatusItemController(store: store)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-popover") {
                self?.statusItemController?.performStatusItemClickForVerification()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard self?.statusItemController?.isPopoverShown == true else {
                        fputs("Menu bar button interaction verification failed\n", stderr)
                        exit(EXIT_FAILURE)
                    }
                    print("Menu bar button interaction verification passed")
                    fflush(stdout)
                    exit(EXIT_SUCCESS)
                }
                return
            }
#endif
            self?.statusItemController?.showPopover()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusItemController?.showPopover()
        return true
    }
}

@main
struct dBDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
