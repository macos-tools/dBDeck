import AppKit
import CoreAudio

struct AudioApp: Identifiable {
    let id: String
    let bundleID: String?
    let name: String
    let icon: NSImage?
    let processIDs: [AudioObjectID]
    let processIdentifiers: [pid_t]

    var supportsPersistence: Bool {
        bundleID != nil
    }
}
