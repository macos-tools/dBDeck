import AppKit
import CoreAudio

struct AudioApp: Identifiable {
    var id: String { bundleID }

    let bundleID: String
    let name: String
    let icon: NSImage
    let bundleURL: URL?
    let processIDs: [AudioObjectID]
    let isPlaying: Bool
    let isRunning: Bool
}
