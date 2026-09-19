import AppKit
import CoreAudio
import Foundation

protocol AudioProcessDiscovering {
    func activeApps() throws -> [AudioApp]
    func activeProcessObjectIDs() throws -> [AudioObjectID]
}

struct AudioProcessDiscovery: AudioProcessDiscovering {
    private struct ActiveProcess {
        let audioObjectID: AudioObjectID
        let pid: pid_t
        let reportedBundleID: String?
    }

    private struct ProcessRecord {
        let audioObjectID: AudioObjectID
        let identity: ApplicationIdentity

        var stableID: String {
            identity.bundleID
        }
    }

    private let identityResolver = ApplicationIdentityResolver()
    private let excludedBundleIDs: Set<String>

    init(excludedBundleIDs: Set<String> = DBDeckApplicationIdentity.bundleIDs) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    func activeApps() throws -> [AudioApp] {
        let records = try resolvedProcessRecords()

        return Dictionary(grouping: records, by: \.stableID)
            .map { _, group in
                AudioApp(
                    identity: group[0].identity,
                    processIDs: group.map(\.audioObjectID).sorted(),
                    isPlaying: true,
                    isRunning: true
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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

    func activeProcessObjectIDs() throws -> [AudioObjectID] {
        try resolvedProcessRecords()
            .map(\.audioObjectID)
            .sorted()
    }

    private func resolvedProcessRecords() throws -> [ProcessRecord] {
        // `processIdentifier` is -1 for apps without a pid, so keys can repeat.
        let runningApplications = Dictionary(
            NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0)
            },
            uniquingKeysWith: { _, latest in latest }
        )

        return try activeProcesses().compactMap { process -> ProcessRecord? in
            guard let identity = identityResolver.resolve(
                pid: process.pid,
                reportedBundleID: process.reportedBundleID,
                runningApplications: runningApplications
            ), !excludedBundleIDs.contains(identity.bundleID) else {
                return nil
            }

            return ProcessRecord(
                audioObjectID: process.audioObjectID,
                identity: identity
            )
        }
    }

    private func activeProcesses() throws -> [ActiveProcess] {
        try activeOutputProcesses().map { process in
            ActiveProcess(
                audioObjectID: process.audioObjectID,
                pid: process.pid,
                reportedBundleID: try? CoreAudioSupport.readString(
                    objectID: process.audioObjectID,
                    selector: kAudioProcessPropertyBundleID,
                    operation: "Read audio process bundle ID"
                )
            )
        }
    }

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
