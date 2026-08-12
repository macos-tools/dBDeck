import Foundation

enum ApplicationDisplayNameResolver {
    static func name(
        for applicationURL: URL,
        preferredLanguages: [String] = Locale.preferredLanguages
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
