import AppKit
import Foundation

final class AudioFixtureDelegate: NSObject, NSApplicationDelegate {
    private var sound: NSSound?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.arguments.count > 1 else {
            exit(EXIT_FAILURE)
        }
        sound = NSSound(contentsOfFile: ProcessInfo.processInfo.arguments[1], byReference: true)
        sound?.loops = true
        guard sound?.play() == true else {
            exit(EXIT_FAILURE)
        }
    }
}

let application = NSApplication.shared
let delegate = AudioFixtureDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
