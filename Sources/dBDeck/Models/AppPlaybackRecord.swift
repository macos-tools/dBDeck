import Foundation

struct AppPlaybackRecord: Codable, Equatable, Identifiable {
    var id: String { bundleID }

    let bundleID: String
    var name: String
    var bundlePath: String?
    var playbackSeconds: TimeInterval
    var lastPlayedAt: Date

    var playbackMinutes: Int {
        Int(playbackSeconds / 60)
    }

    init(
        bundleID: String,
        name: String,
        bundlePath: String?,
        playbackSeconds: TimeInterval = 0,
        lastPlayedAt: Date
    ) {
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.playbackSeconds = playbackSeconds
        self.lastPlayedAt = lastPlayedAt
    }

    init(
        bundleID: String,
        name: String,
        bundlePath: String?,
        playbackMinutes: Int,
        lastPlayedAt: Date
    ) {
        self.init(
            bundleID: bundleID,
            name: name,
            bundlePath: bundlePath,
            playbackSeconds: Double(playbackMinutes * 60),
            lastPlayedAt: lastPlayedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID
        case name
        case bundlePath
        case playbackSeconds
        case playbackMinutes
        case lastPlayedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        name = try container.decode(String.self, forKey: .name)
        bundlePath = try container.decodeIfPresent(String.self, forKey: .bundlePath)
        if let seconds = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .playbackSeconds
        ) {
            playbackSeconds = seconds
        } else {
            let minutes = try container.decodeIfPresent(Int.self, forKey: .playbackMinutes) ?? 0
            playbackSeconds = Double(minutes * 60)
        }
        lastPlayedAt = try container.decode(Date.self, forKey: .lastPlayedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(bundlePath, forKey: .bundlePath)
        try container.encode(playbackSeconds, forKey: .playbackSeconds)
        try container.encode(lastPlayedAt, forKey: .lastPlayedAt)
    }
}

struct PlaybackObservation {
    let bundleID: String
    let name: String
    let bundlePath: String?
}
