import Foundation

enum DBDeckApplicationIdentity {
    static var bundleIDs: Set<String> {
        Set([
            Bundle.main.bundleIdentifier,
            "com.dbdeck.mac",
            "com.dbdeck.app"
        ].compactMap { $0 })
    }
}
