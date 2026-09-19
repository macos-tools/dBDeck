import Foundation

struct AppPlaybackRecord: Codable, Equatable, Identifiable {
    var id: String { bundleID }

    let bundleID: String
    var name: String
    var bundlePath: String?
    var playbackSeconds: TimeInterval = 0
    var lastPlayedAt: Date

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

// In an extension so the memberwise initializer is still synthesized, and so
// only the decoder is hand-written: `encode(to:)` is exactly what synthesis
// produces from CodingKeys above.
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
            // Versions before playback time was tracked in seconds wrote minutes.
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
