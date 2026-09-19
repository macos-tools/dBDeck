import Foundation

extension UserDefaults {
    /// The defaults this app stores its settings and playback history in.
    ///
    /// Normally the standard domain. Debug builds accept `--defaults-suite` to
    /// redirect it, which is how the route verification script exercises the
    /// real binary against real audio without its fixtures reaching anyone's
    /// saved state.
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
