import AppKit
import Foundation

/// Turns playback history rows back into applications the mixer can display.
///
/// A row records that an application played, not where it is now. It may have
/// been moved, updated, or uninstalled since. Resolution tries Launch Services
/// first and the remembered path second, and requires the bundle identifier to
/// match either way so a row cannot latch onto a different application that
/// happens to sit where the old one did.
///
/// Applications that cannot be found are remembered as unavailable and not
/// retried until something suggests they are back — that application launching,
/// or the user asking for a rescan.
final class HistoricalApplicationResolver {
    /// How long a resolved application is trusted to still be installed before
    /// its location is checked again.
    ///
    /// Bounds how long a deleted application can linger in the list, against
    /// checking the filesystem for every row on every refresh.
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
        // Names and icons go as well, so a rescan reflects an application that
        // was moved, renamed or updated rather than reusing what was resolved
        // before.
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
