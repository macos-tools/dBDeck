import Foundation

enum AudioDiscoveryVerificationError: Error {
    case noActiveProcess
}

@main
enum AudioDiscoveryVerifier {
    static func main() throws {
        let apps = try AudioProcessDiscovery().activeApps()
        guard !apps.isEmpty else {
            throw AudioDiscoveryVerificationError.noActiveProcess
        }
        let summary = apps.map { "\($0.name) [\($0.processIDs.count) process(es)]" }.joined(separator: ", ")
        print("Audio process discovery passed: \(summary)")
    }
}
