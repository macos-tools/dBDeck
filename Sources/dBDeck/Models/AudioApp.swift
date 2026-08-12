import AppKit
import CoreAudio

struct AudioApp: Identifiable {
    let id: String
    let bundleID: String?
    let name: String
    let icon: NSImage?
    let bundleURL: URL?
    let processIDs: [AudioObjectID]
    let processIdentifiers: [pid_t]
    let isPlaying: Bool

    var supportsPersistence: Bool {
        bundleID != nil
    }
}
