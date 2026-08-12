import Foundation

enum AudioDiscoveryVerificationError: Error {
    case noActiveProcess
    case unexpectedApplicationName(String)
}

@main
enum AudioDiscoveryVerifier {
    static func main() throws {
        guard ProcessInfo.processInfo.arguments.count > 1 else {
            throw AudioDiscoveryVerificationError.noActiveProcess
        }
        let expectedBundleID = ProcessInfo.processInfo.arguments[1]
        var matchedApp: AudioApp?
        for _ in 0..<30 {
            matchedApp = try AudioProcessDiscovery().activeApps().first {
                $0.bundleID == expectedBundleID
            }
            if matchedApp != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let matchedApp else {
            throw AudioDiscoveryVerificationError.noActiveProcess
        }
        guard matchedApp.name == "dBDeck Audio Fixture" else {
            throw AudioDiscoveryVerificationError.unexpectedApplicationName(matchedApp.name)
        }
        print("Audio application discovery passed: \(matchedApp.name)")
    }
}
