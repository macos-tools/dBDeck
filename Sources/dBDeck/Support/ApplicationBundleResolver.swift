import Foundation

/// Finds the application a path belongs to.
///
/// Audio often comes from a helper nested inside an application rather than the
/// application itself — a browser's renderer, a plug-in host. Walking out to the
/// outermost `.app` is what attributes that audio to the application a person
/// would recognise.
enum ApplicationBundleResolver {
    static func outermostApplicationURL(containing url: URL) -> URL? {
        var applicationURL: URL?
        var current = url.standardizedFileURL

        for _ in 0..<32 {
            if current.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                applicationURL = current
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path.count < current.path.count else { break }
            current = parent
        }
        return applicationURL
    }
}
