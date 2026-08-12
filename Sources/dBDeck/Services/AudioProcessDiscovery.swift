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
        let runningApplications = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0)
            }
        )

        let records = try activeProcesses().compactMap { process -> ProcessRecord? in
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

        return Dictionary(grouping: records, by: \.stableID)
            .map { _, group in
                let identity = group[0].identity
                return AudioApp(
                    bundleID: identity.bundleID,
                    name: identity.name,
                    icon: identity.icon,
                    bundleURL: identity.bundleURL,
                    processIDs: group.map(\.audioObjectID).sorted(),
                    isPlaying: true,
                    isRunning: true
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func activeProcessObjectIDs(for processID: pid_t) throws -> [AudioObjectID] {
        try activeOutputProcesses()
            .filter { $0.pid == processID }
            .map(\.audioObjectID)
            .sorted()
    }

    func activeProcessObjectIDs() throws -> [AudioObjectID] {
        let runningApplications = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0)
            }
        )
        return try activeProcesses().compactMap { process in
            let runningBundleID = runningApplications[process.pid]?.bundleIdentifier
            if process.reportedBundleID.map(excludedBundleIDs.contains) == true
                || runningBundleID.map(excludedBundleIDs.contains) == true {
                return nil
            }
            return process.audioObjectID
        }.sorted()
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
