import Foundation

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
    /// Only records written by older versions can name a bundle nested inside
    /// another app; discovery canonicalizes before writing. Tracking whether any
    /// remain keeps the merge scan off the steady-state path.
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
        // Re-encoding every record on launch is wasted work unless loading
        // actually rewrote something.
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

    /// True when the record names a bundle that lives inside another `.app`.
    /// Pure path arithmetic — no disk access.
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
        // Decorate once rather than recomputing both operands' priority on every
        // comparison. The name tie-break stays locale-aware: collapsing it to a
        // plain string compare would reorder non-ASCII app names.
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
        guard
            let data = defaults.data(forKey: storageKey),
            let records = try? JSONDecoder().decode([AppPlaybackRecord].self, from: data)
        else {
            return ([:], false)
        }
        var normalizedRecords: [String: AppPlaybackRecord] = [:]
        var didNormalize = false
        for decodedRecord in records {
#if DEBUG
            guard !decodedRecord.bundleID.hasPrefix("com.dbdeck.tests.") else {
                didNormalize = true
                continue
            }
#endif
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
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func saveVisibilityState() {
        defaults.set(hiddenBundleIDs.sorted(), forKey: hiddenBundleIDsKey)
        defaults.set(lastVisibilityMaintenanceAt, forKey: lastVisibilityMaintenanceKey)
    }
}
