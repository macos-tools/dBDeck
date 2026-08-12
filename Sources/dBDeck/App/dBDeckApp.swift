import AppKit
import SwiftUI
#if DEBUG
import WidgetKit
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: AppAudioStore?
    private var mixerPanelController: MixerPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("dBDeck audio service")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.setActivationPolicy(.accessory)

#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--verify-control") {
            if #available(macOS 26.0, *) {
                Task {
                    do {
                        let controls = try await ControlCenter.shared.currentControls()
                        guard controls.contains(where: {
                            $0.kind == "com.dbdeck.app.control.mixer"
                        }) else {
                            fputs("Control Center configuration verification failed\n", stderr)
                            exit(EXIT_FAILURE)
                        }
                        print("Control Center configuration verification passed")
                        fflush(stdout)
                        exit(EXIT_SUCCESS)
                    } catch {
                        fputs("Control Center verification failed: \(error.localizedDescription)\n", stderr)
                        exit(EXIT_FAILURE)
                    }
                }
            } else {
                fputs("Control Center verification requires macOS 26\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }

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
        mixerPanelController = MixerPanelController(store: store)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.mixerPanelController?.show()

#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--verify-panel") {
                guard self?.mixerPanelController?.isVisible == true else {
                    fputs("Quick mixer panel verification failed\n", stderr)
                    exit(EXIT_FAILURE)
                }
                print("Quick mixer panel verification passed")
                fflush(stdout)
                exit(EXIT_SUCCESS)
            }
#endif
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        mixerPanelController?.show()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "dbdeck" }) else { return }
        mixerPanelController?.show()
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
