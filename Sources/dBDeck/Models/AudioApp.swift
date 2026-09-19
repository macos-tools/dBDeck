import AppKit
import CoreAudio

/// An application as the mixer presents it: one row, however many audio
/// process objects it actually owns.
///
/// `isPlaying` means audio is coming out of it right now; `isRunning` means it
/// is open but silent. A row with neither is history.
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
    /// Compares the fields that decide what a row shows.
    ///
    /// `icon` is excluded because `NSWorkspace` returns a fresh `NSImage` for
    /// every request, which would make two otherwise identical values unequal.
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
