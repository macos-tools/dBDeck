import Foundation

/// Remembers which applications have played audio, for how long, and how
/// recently.
///
/// This is what lets the mixer show an application that is not playing right
/// now. Rows are ranked playing first, then running, then by accumulated
/// playback time, so a list built from it is stable between sessions.
///
/// Left alone the list would only grow, so once it exceeds
/// `visibleHistoryLimit` entries anything untouched for `dormantHistoryInterval`
/// is hidden. That pass runs at most once every `visibilityMaintenanceInterval`,
/// because rows disappearing while someone is looking at them is worse than
/// carrying a few extra for a day. Hidden rows are kept, not deleted: playing or
/// launching the application brings it straight back with its history intact.
///
/// Records are keyed by bundle identifier, which is also how they are matched
/// against live discovery, so a row and a playing application have to agree on
/// it. Helper processes inside an application bundle are folded into their
/// parent so an application cannot occupy several rows.
final class PlaybackHistoryStore {
    static let visibleHistoryLimit = 10
    static let dormantHistoryInterval: TimeInterval = 7 * 24 * 60 * 60
    static let visibilityMaintenanceInterval: TimeInterval = 24 * 60 * 60

    private let defaults: UserDefaults
    private let storageKey: String
    private let hiddenBundleIDsKey: String
    private let lastVisibilityMaintenanceKey: String
    private var recordsByBundleID: [String: AppPlaybackRecord]
    private var hiddenBundleIDs: Set<String>
    private var lastVisibilityMaintenanceAt: Date?
    /// Whether any record names a bundle nested inside another application, and
    /// so might still need folding into its parent.
    ///
    /// Records created from discovery are already resolved to the outermost
    /// application, so in the ordinary case this is false and the fold is
    /// skipped entirely.
    private var mayHaveNestedRecords: Bool

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "appPlaybackHistory.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        hiddenBundleIDsKey = storageKey + ".hiddenBundleIDs"
        lastVisibilityMaintenanceKey = storageKey + ".lastVisibilityMaintenanceAt"
        let loaded = Self.load(defaults: defaults, storageKey: storageKey)
        recordsByBundleID = loaded.records
        mayHaveNestedRecords = loaded.records.values.contains(where: Self.isNested)
        hiddenBundleIDs = Set(defaults.stringArray(forKey: hiddenBundleIDsKey) ?? [])
        lastVisibilityMaintenanceAt = defaults.object(
            forKey: lastVisibilityMaintenanceKey
        ) as? Date
        // Loading only writes back when it had to reshape what it read.
        if loaded.didNormalize {
            save()
        }
    }

    var records: [AppPlaybackRecord] {
        Array(recordsByBundleID.values)
    }

    func containsRecord(for bundleID: String) -> Bool {
        recordsByBundleID[bundleID] != nil
    }

    func removeRecords(for bundleIDs: Set<String>) {
        let countBeforeRemoval = recordsByBundleID.count
        for bundleID in bundleIDs {
            recordsByBundleID[bundleID] = nil
        }
        let recordsChanged = recordsByBundleID.count != countBeforeRemoval
        let hiddenChanged = !hiddenBundleIDs.isDisjoint(with: bundleIDs)
        hiddenBundleIDs.subtract(bundleIDs)
        if recordsChanged {
            save()
        }
        if hiddenChanged {
            saveVisibilityState()
        }
    }

    /// Credits `elapsed` seconds to each observed application and records that
    /// it played at `now`.
    ///
    /// Called with zero elapsed to note that an application is playing without
    /// yet crediting time; the interval is credited on the following call.
    func observe(
        _ observations: [PlaybackObservation],
        elapsed: TimeInterval,
        now: Date = Date()
    ) {
        var needsSave = false
        let creditedSeconds = max(elapsed, 0)

        for observation in observations {
            let nestedRecordIDs = mayHaveNestedRecords
                ? recordsByBundleID.values.compactMap { record -> String? in
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
                : []
            let inheritedSeconds = nestedRecordIDs.reduce(0) {
                $0 + (recordsByBundleID[$1]?.playbackSeconds ?? 0)
            }
            for nestedRecordID in nestedRecordIDs {
                recordsByBundleID[nestedRecordID] = nil
                needsSave = true
            }

            let existingRecord = recordsByBundleID[observation.bundleID]
            var record = existingRecord ?? AppPlaybackRecord(
                bundleID: observation.bundleID,
                name: observation.name,
                bundlePath: observation.bundlePath,
                lastPlayedAt: now
            )
            record.playbackSeconds += inheritedSeconds

            if existingRecord == nil
                || record.name != observation.name
                || record.bundlePath != observation.bundlePath {
                needsSave = true
            }

            record.name = observation.name
            record.bundlePath = observation.bundlePath
            record.lastPlayedAt = now

            if creditedSeconds > 0 {
                record.playbackSeconds += creditedSeconds
                needsSave = true
            }
            recordsByBundleID[observation.bundleID] = record
            if existingRecord == nil, Self.isNested(record) {
                mayHaveNestedRecords = true
            }
        }

        if needsSave {
            save()
            mayHaveNestedRecords = recordsByBundleID.values.contains(where: Self.isNested)
        }
    }

    /// Whether the record's bundle lives inside another `.app`, such as a helper
    /// process under its parent application.
    ///
    /// Decided from the path alone, with no filesystem access.
    private static func isNested(_ record: AppPlaybackRecord) -> Bool {
        guard let bundlePath = record.bundlePath else { return false }
        let originalURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
        guard let applicationURL = ApplicationBundleResolver
            .outermostApplicationURL(containing: originalURL)
        else {
            return false
        }
        return applicationURL != originalURL
    }

    func prioritizedRecords(
        playingBundleIDs: Set<String>,
        runningBundleIDs: Set<String>
    ) -> [AppPlaybackRecord] {
        // Each record's tier is worked out once and carried into the sort,
        // rather than being recomputed for both sides of every comparison. The
        // name tie-break stays locale-aware, since ordering names by raw code
        // point would be wrong in most languages.
        recordsByBundleID.values
            .map { record in
                (
                    priority: priority(
                        for: record.bundleID,
                        playingBundleIDs: playingBundleIDs,
                        runningBundleIDs: runningBundleIDs
                    ),
                    record: record
                )
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                if lhs.record.playbackSeconds != rhs.record.playbackSeconds {
                    return lhs.record.playbackSeconds > rhs.record.playbackSeconds
                }
                return lhs.record.name
                    .localizedCaseInsensitiveCompare(rhs.record.name) == .orderedAscending
            }
            .map(\.record)
    }

    /// Runs the dormancy pass that decides which rows are hidden.
    ///
    /// Anything playing or running is unhidden immediately; the rest of the pass
    /// is rate limited to `visibilityMaintenanceInterval` so the list does not
    /// rearrange itself under the reader.
    func updateHiddenRecordsIfNeeded(
        installedRecords: [AppPlaybackRecord],
        playingBundleIDs: Set<String>,
        runningBundleIDs: Set<String>,
        now: Date
    ) {
        let activeBundleIDs = playingBundleIDs.union(runningBundleIDs)
        let previousHiddenBundleIDs = hiddenBundleIDs
        hiddenBundleIDs.subtract(activeBundleIDs)

        let isMaintenanceDue = lastVisibilityMaintenanceAt.map {
            now.timeIntervalSince($0) >= Self.visibilityMaintenanceInterval
        } ?? true
        guard isMaintenanceDue else {
            if hiddenBundleIDs != previousHiddenBundleIDs {
                saveVisibilityState()
            }
            return
        }

        lastVisibilityMaintenanceAt = now
        if installedRecords.count > Self.visibleHistoryLimit {
            let dormantThreshold = now.addingTimeInterval(-Self.dormantHistoryInterval)
            hiddenBundleIDs = Set(installedRecords.compactMap { record in
                guard !activeBundleIDs.contains(record.bundleID),
                      record.lastPlayedAt < dormantThreshold
                else {
                    return nil
                }
                return record.bundleID
            })
        } else {
            hiddenBundleIDs.removeAll()
        }
        saveVisibilityState()
    }

    func isHiddenFromList(
        bundleID: String,
        playingBundleIDs: Set<String>,
        runningBundleIDs: Set<String>
    ) -> Bool {
        hiddenBundleIDs.contains(bundleID)
            && !playingBundleIDs.contains(bundleID)
            && !runningBundleIDs.contains(bundleID)
    }

    private func priority(
        for bundleID: String,
        playingBundleIDs: Set<String>,
        runningBundleIDs: Set<String>
    ) -> Int {
        if playingBundleIDs.contains(bundleID) { return 0 }
        if runningBundleIDs.contains(bundleID) { return 1 }
        return 2
    }

    private static func load(
        defaults: UserDefaults,
        storageKey: String
    ) -> (records: [String: AppPlaybackRecord], didNormalize: Bool) {
        guard let records = defaults.codable([AppPlaybackRecord].self, forKey: storageKey) else {
            return ([:], false)
        }
        var normalizedRecords: [String: AppPlaybackRecord] = [:]
        var didNormalize = false
        for decodedRecord in records {
            let record = canonicalizedRecord(decodedRecord)
            if record != decodedRecord {
                didNormalize = true
            }
            if var existing = normalizedRecords[record.bundleID] {
                didNormalize = true
                existing.playbackSeconds += record.playbackSeconds
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
        return (normalizedRecords, didNormalize)
    }

    private static func canonicalizedRecord(
        _ record: AppPlaybackRecord
    ) -> AppPlaybackRecord {
        guard let bundlePath = record.bundlePath else { return record }
        let originalURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
        guard
            let applicationURL = ApplicationBundleResolver
                .outermostApplicationURL(containing: originalURL),
            applicationURL != originalURL,
            let identity = ApplicationIdentityResolver.identity(forApplicationURL: applicationURL)
        else {
            return record
        }

        return AppPlaybackRecord(
            bundleID: identity.bundleID,
            name: identity.name,
            bundlePath: applicationURL.path,
            playbackSeconds: record.playbackSeconds,
            lastPlayedAt: record.lastPlayedAt
        )
    }

    private func save() {
        defaults.setCodable(records, forKey: storageKey)
    }

    private func saveVisibilityState() {
        defaults.set(hiddenBundleIDs.sorted(), forKey: hiddenBundleIDsKey)
        defaults.set(lastVisibilityMaintenanceAt, forKey: lastVisibilityMaintenanceKey)
    }
}
