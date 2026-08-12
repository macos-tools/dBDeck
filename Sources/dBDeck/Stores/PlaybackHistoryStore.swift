import Foundation

final class PlaybackHistoryStore {
    private let defaults: UserDefaults
    private let storageKey: String
    private var recordsByBundleID: [String: AppPlaybackRecord]
    private var pendingSecondsByBundleID: [String: TimeInterval] = [:]

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "appPlaybackHistory.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        recordsByBundleID = Self.load(defaults: defaults, storageKey: storageKey)
        save()
    }

    var records: [AppPlaybackRecord] {
        Array(recordsByBundleID.values)
    }

    func observe(
        _ observations: [PlaybackObservation],
        elapsed: TimeInterval,
        now: Date = Date()
    ) {
        var needsSave = false
        let creditedSeconds = min(max(elapsed, 0), 5)

        for observation in observations {
            let nestedRecordIDs = recordsByBundleID.values.compactMap { record -> String? in
                guard
                    record.bundleID != observation.bundleID,
                    let appPath = observation.bundlePath,
                    let recordPath = record.bundlePath,
                    recordPath.hasPrefix(appPath + "/")
                else {
                    return nil
                }
                return record.bundleID
            }
            let inheritedMinutes = nestedRecordIDs.reduce(0) {
                $0 + (recordsByBundleID[$1]?.playbackMinutes ?? 0)
            }
            let inheritedSeconds = nestedRecordIDs.reduce(0) {
                $0 + (pendingSecondsByBundleID[$1] ?? 0)
            }
            for nestedRecordID in nestedRecordIDs {
                recordsByBundleID[nestedRecordID] = nil
                pendingSecondsByBundleID[nestedRecordID] = nil
                needsSave = true
            }

            var record = recordsByBundleID[observation.bundleID] ?? AppPlaybackRecord(
                bundleID: observation.bundleID,
                name: observation.name,
                bundlePath: observation.bundlePath,
                playbackMinutes: inheritedMinutes,
                lastPlayedAt: now
            )
            if recordsByBundleID[observation.bundleID] != nil {
                record.playbackMinutes += inheritedMinutes
            }

            if recordsByBundleID[observation.bundleID] == nil
                || record.name != observation.name
                || record.bundlePath != observation.bundlePath {
                needsSave = true
            }

            record.name = observation.name
            record.bundlePath = observation.bundlePath
            record.lastPlayedAt = now

            let pendingSeconds = pendingSecondsByBundleID[observation.bundleID, default: 0]
                + inheritedSeconds
                + creditedSeconds
            let completedMinutes = Int(pendingSeconds / 60)
            pendingSecondsByBundleID[observation.bundleID] = pendingSeconds
                - Double(completedMinutes * 60)

            if completedMinutes > 0 {
                record.playbackMinutes += completedMinutes
                needsSave = true
            }
            recordsByBundleID[observation.bundleID] = record
        }

        if needsSave {
            save()
        }
    }

    func prioritizedRecords(activeBundleIDs: Set<String>) -> [AppPlaybackRecord] {
        records.sorted { lhs, rhs in
            let lhsIsActive = activeBundleIDs.contains(lhs.bundleID)
            let rhsIsActive = activeBundleIDs.contains(rhs.bundleID)
            if lhsIsActive != rhsIsActive {
                return lhsIsActive
            }
            if lhs.playbackMinutes != rhs.playbackMinutes {
                return lhs.playbackMinutes > rhs.playbackMinutes
            }
            if lhs.lastPlayedAt != rhs.lastPlayedAt {
                return lhs.lastPlayedAt > rhs.lastPlayedAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func load(
        defaults: UserDefaults,
        storageKey: String
    ) -> [String: AppPlaybackRecord] {
        guard
            let data = defaults.data(forKey: storageKey),
            let records = try? JSONDecoder().decode([AppPlaybackRecord].self, from: data)
        else {
            return [:]
        }
        var normalizedRecords: [String: AppPlaybackRecord] = [:]
        for decodedRecord in records {
#if DEBUG
            guard !decodedRecord.bundleID.hasPrefix("com.dbdeck.tests.") else {
                continue
            }
#endif
            let record = canonicalizedRecord(decodedRecord)
            if var existing = normalizedRecords[record.bundleID] {
                existing.playbackMinutes += record.playbackMinutes
                if record.lastPlayedAt > existing.lastPlayedAt {
                    existing.name = record.name
                    existing.bundlePath = record.bundlePath
                    existing.lastPlayedAt = record.lastPlayedAt
                }
                normalizedRecords[record.bundleID] = existing
            } else {
                normalizedRecords[record.bundleID] = record
            }
        }
        return normalizedRecords
    }

    private static func canonicalizedRecord(
        _ record: AppPlaybackRecord
    ) -> AppPlaybackRecord {
        guard let bundlePath = record.bundlePath else { return record }
        let originalURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
        var applicationURL = originalURL
        var current = originalURL

        for _ in 0..<32 {
            if current.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                applicationURL = current
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path.count < current.path.count else { break }
            current = parent
        }

        guard
            applicationURL != originalURL,
            let bundle = Bundle(url: applicationURL),
            let bundleID = bundle.bundleIdentifier
        else {
            return record
        }

        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
        return AppPlaybackRecord(
            bundleID: bundleID,
            name: name,
            bundlePath: applicationURL.path,
            playbackMinutes: record.playbackMinutes,
            lastPlayedAt: record.lastPlayedAt
        )
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
