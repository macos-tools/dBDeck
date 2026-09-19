import AppKit
import CoreAudio
import Foundation

/// One traversal's worth of discovery.
struct DiscoverySnapshot {
    /// The audio process objects producing output, before identity resolution
    /// or exclusion.
    ///
    /// This is what `apps` was derived from, kept alongside it so a later cheap
    /// read can be compared against the same shape. It deliberately includes
    /// processes that never reach `apps`.
    let signature: [AudioObjectID]

    /// One entry per application, with every audio process object it owns
    /// gathered under it.
    let apps: [AudioApp]
}

/// Answers which applications are currently producing audio.
///
/// Two levels of detail are offered because they cost very different amounts.
/// Resolving an application from an audio process means consulting the running
/// application list, loading bundles, reading localized names off disk and, for
/// processes that do not identify themselves, walking up the parent process
/// chain. Reading which process objects are producing output is a handful of
/// Core Audio property reads. Callers that only need to know whether anything
/// changed use the second.
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

    /// The cheap half of `snapshot()`: Core Audio property reads only, with no
    /// AppKit, disk or sysctl access, so it is affordable to poll.
    func processSignature() throws -> [AudioObjectID] {
        try activeOutputProcesses().map(\.audioObjectID).sorted()
    }

    func snapshot() throws -> DiscoverySnapshot {
        let processes = try activeOutputProcesses()
        let runningApplications = Dictionary(
            // Apps without a pid all report -1, so this key is not unique.
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

    /// Audio process objects that are currently producing output, excluding this
    /// app's own, which would otherwise be tapped by its own mixer.
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
