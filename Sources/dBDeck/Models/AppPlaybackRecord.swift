import Foundation

/// One application's entry in the playback history.
///
/// Keyed by bundle identifier, which is also how it is matched against live
/// discovery. `bundlePath` is the last place the application was seen, used to
/// find it again if it is no longer registered with Launch Services.
struct AppPlaybackRecord: Codable, Equatable, Identifiable {
    var id: String { bundleID }

    let bundleID: String
    var name: String
    var bundlePath: String?
    var playbackSeconds: TimeInterval = 0
    var lastPlayedAt: Date

    /// Playback time at the resolution it was stored in before seconds, and the
    /// value the legacy decoding path below reads back.
    var playbackMinutes: Int {
        Int(playbackSeconds / 60)
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID
        case name
        case bundlePath
        case playbackSeconds
        case lastPlayedAt
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case playbackMinutes
    }
}

// Declared in an extension so the memberwise initializer is still synthesized.
// Only decoding is hand-written, to accept the older on-disk shape; encoding is
// whatever the coding keys above describe.
extension AppPlaybackRecord {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
        lastPlayedAt = try container.decode(Date.self, forKey: .lastPlayedAt)

        if let seconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .playbackSeconds
        ) {
            playbackSeconds = seconds
        } else {
            // Playback time was stored as whole minutes before it was stored
            // as seconds. Reading it back at minute resolution keeps a long
            // history rather than resetting the totals.
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let minutes = try legacy.decodeIfPresent(Int.self, forKey: .playbackMinutes) ?? 0
            playbackSeconds = Double(minutes * 60)
        }
    }
}

struct PlaybackObservation {
    let bundleID: String
    let name: String
    let bundlePath: String?
}
