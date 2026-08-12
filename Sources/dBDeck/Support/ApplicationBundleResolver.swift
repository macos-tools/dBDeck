import Foundation

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
