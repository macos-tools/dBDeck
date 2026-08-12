import Foundation

struct AppPlaybackRecord: Codable, Equatable, Identifiable {
    var id: String { bundleID }

    let bundleID: String
    var name: String
    var bundlePath: String?
    var playbackMinutes: Int
    var lastPlayedAt: Date
}

struct PlaybackObservation {
    let bundleID: String
    let name: String
    let bundlePath: String?
}
