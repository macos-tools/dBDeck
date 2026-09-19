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

extension AudioApp {
    init(
        identity: ApplicationIdentity,
        processIDs: [AudioObjectID],
        isPlaying: Bool,
        isRunning: Bool
    ) {
        self.init(
            bundleID: identity.bundleID,
            name: identity.name,
            icon: identity.icon,
            bundleURL: identity.bundleURL,
            processIDs: processIDs,
            isPlaying: isPlaying,
            isRunning: isRunning
        )
    }
}

extension AudioApp: Equatable {
    /// `icon` is deliberately excluded: `NSWorkspace.icon(forFile:)` hands back a
    /// fresh `NSImage` per call, so comparing it would defeat change detection.
    /// `id` is excluded because it is `bundleID`.
    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.bundleID == rhs.bundleID
            && lhs.name == rhs.name
            && lhs.bundleURL == rhs.bundleURL
            && lhs.processIDs == rhs.processIDs
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isRunning == rhs.isRunning
    }
}
