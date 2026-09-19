import AppKit
import Foundation

final class HistoricalApplicationResolver {
    /// How long a resolved app is trusted to still be installed before its path
    /// is stat'd again. Without a budget every history row cost a syscall on
    /// every refresh, including cache hits.
    static let availabilityRecheckInterval: TimeInterval = 10

    private struct CachedIdentity {
        let identity: ApplicationIdentity
        var verifiedAt: Date
    }

    private var identitiesByBundleID: [String: CachedIdentity] = [:]
    private var unavailableBundleIDs = Set<String>()

    func audioApp(from record: AppPlaybackRecord, isRunning: Bool) -> AudioApp? {
        guard let identity = identity(for: record) else { return nil }
        return AudioApp(
            identity: identity,
            processIDs: [],
            isPlaying: false,
            isRunning: isRunning
        )
    }

    func retryUnavailableApplication(bundleID: String) {
        unavailableBundleIDs.remove(bundleID)
    }

    func retryAllUnavailableApplications() {
        unavailableBundleIDs.removeAll()
        // Drop resolved names and icons too, so an explicit rescan picks up an
        // app that was moved, renamed or updated in place.
        identitiesByBundleID.removeAll()
    }

    private func identity(
        for record: AppPlaybackRecord,
        now: Date = Date()
    ) -> ApplicationIdentity? {
        guard !unavailableBundleIDs.contains(record.bundleID) else { return nil }

        if var cached = identitiesByBundleID[record.bundleID] {
            guard now.timeIntervalSince(cached.verifiedAt) >= Self.availabilityRecheckInterval
            else {
                return cached.identity
            }
            if let bundleURL = cached.identity.bundleURL,
               isAvailableApplicationURL(bundleURL) {
                cached.verifiedAt = now
                identitiesByBundleID[record.bundleID] = cached
                return cached.identity
            }
            identitiesByBundleID[record.bundleID] = nil
        }

        guard
            let bundleURL = installedApplicationURL(for: record),
            let identity = ApplicationIdentityResolver.identity(forApplicationURL: bundleURL)
        else {
            unavailableBundleIDs.insert(record.bundleID)
            return nil
        }
        identitiesByBundleID[record.bundleID] = CachedIdentity(
            identity: identity,
            verifiedAt: now
        )
        return identity
    }

    private func installedApplicationURL(for record: AppPlaybackRecord) -> URL? {
        let currentURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: record.bundleID
        )
        let storedURL = record.bundlePath.map { URL(fileURLWithPath: $0) }

        return [currentURL, storedURL]
            .compactMap { $0 }
            .first { url in
                guard isAvailableApplicationURL(url),
                      let bundle = Bundle(url: url)
                else {
                    return false
                }
                return bundle.bundleIdentifier == record.bundleID
            }
    }

    private func isAvailableApplicationURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return !path.contains("/.Trash/")
            && FileManager.default.fileExists(atPath: path)
    }
}
