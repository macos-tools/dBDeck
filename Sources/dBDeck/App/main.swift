import AppKit

// This app has no SwiftUI scene. Its entire interface is the status item's
// panel and the recovery window, both built by AppDelegate, so there is nothing
// for a `Scene` to describe. Declaring a SwiftUI `App` would require one
// anyway, and the usual empty stand-in — a `Settings` scene — presents itself
// at launch as a blank window when it is the only scene the app has.

/// `NSApplication` refers to its delegate weakly, so the delegate needs an
/// owner that outlives launch.
@MainActor
private enum Launcher {
    static var delegate: AppDelegate?

    static func start() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

// Top-level code runs on the main thread, which is the main actor's executor.
MainActor.assumeIsolated {
    Launcher.start()
}
