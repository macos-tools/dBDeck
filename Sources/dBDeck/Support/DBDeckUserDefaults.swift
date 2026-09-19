import Foundation

extension UserDefaults {
    /// The defaults this app stores its state in.
    ///
    /// Verification runs launch the real app binary while audio plays, which
    /// would otherwise write fixture apps into the user's real playback
    /// history. They pass a throwaway suite instead, so nothing has to be
    /// scrubbed back out afterwards.
    static var dbdeck: UserDefaults {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flagIndex = arguments.firstIndex(of: "--defaults-suite"),
           case let suiteIndex = arguments.index(after: flagIndex),
           suiteIndex < arguments.endIndex,
           let suite = UserDefaults(suiteName: arguments[suiteIndex]) {
            return suite
        }
#endif
        return .standard
    }
}
