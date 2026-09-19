import Foundation

enum DBDeckApplicationIdentity {
    /// Excluded from discovery so the mixer never lists itself. The live filter
    /// is the app's own identity and nothing else; `AudioProcessDiscovery` also
    /// drops its own pid, so this is belt-and-braces rather than the mechanism.
    static var bundleIDs: Set<String> {
        Set([Bundle.main.bundleIdentifier].compactMap { $0 })
    }

    /// Bundle IDs earlier versions of this app shipped under. Used once, at
    /// launch, to delete rows they wrote. Keeping them in the live filter would
    /// permanently hide any unrelated app that ever shipped under one, and the
    /// list could only ever grow.
    static let legacyBundleIDs: Set<String> = ["com.dbdeck.app"]
}
