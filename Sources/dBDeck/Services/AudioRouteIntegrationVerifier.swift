#if DEBUG
import Foundation

enum AudioRouteVerificationError: LocalizedError {
    case invalidProcessID
    case processNotDiscovered(pid_t)

    var errorDescription: String? {
        switch self {
        case .invalidProcessID:
            return "The route verifier requires a valid audio process ID"
        case .processNotDiscovered(let pid):
            return "Core Audio did not discover process \(pid) producing audio"
        }
    }
}

struct AudioRouteIntegrationVerifier {
    func run(processID: pid_t) throws {
        guard processID > 0 else {
            throw AudioRouteVerificationError.invalidProcessID
        }

        var targetApp: AudioApp?
        for _ in 0..<30 {
            targetApp = try AudioProcessDiscovery()
                .activeApps()
                .first { $0.processIdentifiers.contains(processID) }
            if targetApp != nil {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        guard let targetApp else {
            throw AudioRouteVerificationError.processNotDiscovered(processID)
        }

        let route = try ProcessAudioRoute(
            appID: "integration-verifier",
            processIDs: targetApp.processIDs,
            gain: 0.25
        )
        Thread.sleep(forTimeInterval: 0.8)
        route.setGain(0)
        Thread.sleep(forTimeInterval: 0.2)
        route.stop()
    }
}
#endif
