import AppKit
import CoreAudio
import Foundation

/// One traversal's worth of discovery: the resolved apps, plus the raw process
/// list they were derived from.
struct DiscoverySnapshot {
    /// Audio-process object IDs producing output, before identity resolution or
    /// exclusion. Core Audio property reads only — no AppKit, no disk, no
    /// sysctl — so it is cheap enough to poll as a change signal.
    let signature: [AudioObjectID]
    let apps: [AudioApp]
}

protocol AudioProcessDiscovering {
    func snapshot() throws -> DiscoverySnapshot
    func processSignature() throws -> [AudioObjectID]
}

struct AudioProcessDiscovery: AudioProcessDiscovering {
    private let identityResolver = ApplicationIdentityResolver()
    private let excludedBundleIDs: Set<String>

    init(excludedBundleIDs: Set<String> = DBDeckApplicationIdentity.bundleIDs) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    func processSignature() throws -> [AudioObjectID] {
        try activeOutputProcesses().map(\.audioObjectID).sorted()
    }

    func snapshot() throws -> DiscoverySnapshot {
        let processes = try activeOutputProcesses()
        let runningApplications = Dictionary(
            // `processIdentifier` is -1 for apps without a pid, so keys can repeat.
            NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        let resolved = processes.compactMap {
            process -> (audioObjectID: AudioObjectID, identity: ApplicationIdentity)? in
            let reportedBundleID = try? CoreAudioSupport.readString(
                objectID: process.audioObjectID,
                selector: kAudioProcessPropertyBundleID,
                operation: "Read audio process bundle ID"
            )
            guard let identity = identityResolver.resolve(
                pid: process.pid,
                reportedBundleID: reportedBundleID,
                runningApplications: runningApplications
            ), !excludedBundleIDs.contains(identity.bundleID) else {
                return nil
            }
            return (process.audioObjectID, identity)
        }

        let apps = Dictionary(grouping: resolved, by: { $0.identity.bundleID })
            .map { _, group in
                AudioApp(
                    identity: group[0].identity,
                    processIDs: group.map(\.audioObjectID).sorted(),
                    isPlaying: true,
                    isRunning: true
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return DiscoverySnapshot(
            signature: processes.map(\.audioObjectID).sorted(),
            apps: apps
        )
    }

#if DEBUG
    /// Used only by `AudioRouteIntegrationVerifier`, which is itself `#if DEBUG`.
    func activeProcessObjectIDs(for processID: pid_t) throws -> [AudioObjectID] {
        try activeOutputProcesses()
            .filter { $0.pid == processID }
            .map(\.audioObjectID)
            .sorted()
    }
#endif

    private func activeOutputProcesses() throws -> [(audioObjectID: AudioObjectID, pid: pid_t)] {
        let processObjectIDs = try CoreAudioSupport.readObjectIDs(
            objectID: CoreAudioSupport.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList,
            operation: "Read audio process list"
        )

        return processObjectIDs.compactMap { objectID in
            guard
                let isRunningOutput: UInt32 = try? CoreAudioSupport.readInteger(
                    objectID: objectID,
                    selector: kAudioProcessPropertyIsRunningOutput,
                    defaultValue: 0,
                    operation: "Read process output state"
                ),
                isRunningOutput != 0,
                let pid: pid_t = try? CoreAudioSupport.readInteger(
                    objectID: objectID,
                    selector: kAudioProcessPropertyPID,
                    defaultValue: 0,
                    operation: "Read audio process PID"
                ),
                pid != getpid()
            else {
                return nil
            }

            return (objectID, pid)
        }
    }
}
