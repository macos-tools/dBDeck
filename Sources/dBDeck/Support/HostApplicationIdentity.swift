import Foundation

/// How the mixer recognises itself.
enum DBDeckApplicationIdentity {
    /// Identities the mixer never lists, so it cannot appear in its own list.
    ///
    /// Discovery also drops its own process by pid, which is the primary
    /// mechanism; this covers the stored side, where a bundle identifier is all
    /// there is to match on.
    static var bundleIDs: Set<String> {
        Set([Bundle.main.bundleIdentifier].compactMap { $0 })
    }

    /// Bundle identifiers earlier versions of this app shipped under.
    ///
    /// Applied once at launch to discard rows they left behind. They are kept
    /// separate from the live exclusions because an identifier this app no
    /// longer uses is one another application may legitimately claim.
    static let legacyBundleIDs: Set<String> = ["com.dbdeck.app"]
}
