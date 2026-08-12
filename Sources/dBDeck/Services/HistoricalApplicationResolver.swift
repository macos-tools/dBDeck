import AppKit
import Foundation

final class HistoricalApplicationResolver {
    private struct Metadata {
        let bundleURL: URL
        let name: String
        let icon: NSImage
    }

    private var metadataByBundleID: [String: Metadata] = [:]
    private var unavailableBundleIDs = Set<String>()

    func audioApp(from record: AppPlaybackRecord, isRunning: Bool) -> AudioApp? {
        guard let metadata = metadata(for: record) else { return nil }
        return AudioApp(
            bundleID: record.bundleID,
            name: metadata.name,
            icon: metadata.icon,
            bundleURL: metadata.bundleURL,
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
    }

    private func metadata(for record: AppPlaybackRecord) -> Metadata? {
        guard !unavailableBundleIDs.contains(record.bundleID) else { return nil }
        if let cached = metadataByBundleID[record.bundleID],
           isAvailableApplicationURL(cached.bundleURL) {
            return cached
        }
        metadataByBundleID[record.bundleID] = nil

        guard let bundleURL = installedApplicationURL(for: record) else {
            unavailableBundleIDs.insert(record.bundleID)
            return nil
        }
        let metadata = Metadata(
            bundleURL: bundleURL,
            name: ApplicationDisplayNameResolver.name(for: bundleURL),
            icon: NSWorkspace.shared.icon(forFile: bundleURL.path)
        )
        metadataByBundleID[record.bundleID] = metadata
        return metadata
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
