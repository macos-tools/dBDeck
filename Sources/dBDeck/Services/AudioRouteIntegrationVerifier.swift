#if DEBUG
import CoreAudio
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

        var processObjectIDs: [AudioObjectID] = []
        for _ in 0..<30 {
            processObjectIDs = try AudioProcessDiscovery()
                .activeProcessObjectIDs(for: processID)
            if !processObjectIDs.isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        guard !processObjectIDs.isEmpty else {
            throw AudioRouteVerificationError.processNotDiscovered(processID)
        }

        let route = try ProcessAudioRoute(
            appID: "integration-verifier",
            processIDs: processObjectIDs,
            gain: 0.25
        )
        Thread.sleep(forTimeInterval: 0.8)
        route.setGain(0)
        Thread.sleep(forTimeInterval: 0.2)
        route.stop()
    }
}
#endif
