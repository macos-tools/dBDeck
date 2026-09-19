import Foundation

enum ApplicationDisplayNameResolver {
    private static let cacheLock = NSLock()
    private static var cachedNames: [String: String] = [:]

    /// Called when the user asks for a rescan, so an app updated in place is
    /// picked up rather than kept under its old name for the session.
    static func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedNames.removeAll()
    }

    static func name(
        for applicationURL: URL,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        // The language preferences are part of the key, so a caller passing its
        // own preferences never reads a name resolved under different ones.
        let cacheKey = applicationURL.standardizedFileURL.path
            + "\u{0}"
            + preferredLanguages.joined(separator: ",")
        cacheLock.lock()
        let cachedName = cachedNames[cacheKey]
        cacheLock.unlock()
        if let cachedName {
            return cachedName
        }

        let name = resolvedName(for: applicationURL, preferredLanguages: preferredLanguages)
        cacheLock.lock()
        cachedNames[cacheKey] = name
        cacheLock.unlock()
        return name
    }

    private static func resolvedName(
        for applicationURL: URL,
        preferredLanguages: [String]
    ) -> String {
        guard let bundle = Bundle(url: applicationURL) else {
            return applicationURL.deletingPathExtension().lastPathComponent
        }

        let preferredLocalizations = Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: preferredLanguages
        )
        for localization in preferredLocalizations {
            guard
                let stringsURL = bundle.url(
                    forResource: "InfoPlist",
                    withExtension: "strings",
                    subdirectory: nil,
                    localization: localization
                ),
                let data = try? Data(contentsOf: stringsURL),
                let strings = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any],
                let name = displayName(in: strings)
            else {
                continue
            }
            return name
        }

        return displayName(in: bundle.infoDictionary ?? [:])
            ?? applicationURL.deletingPathExtension().lastPathComponent
    }

    private static func displayName(in info: [String: Any]) -> String? {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let value = info[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
