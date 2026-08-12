import AppKit
import CoreAudio
import Foundation

struct AudioProcessDiscovery {
    private struct ActiveProcess {
        let audioObjectID: AudioObjectID
        let pid: pid_t
        let reportedBundleID: String?
    }

    private struct ProcessRecord {
        let audioObjectID: AudioObjectID
        let pid: pid_t
        let identity: ApplicationIdentity

        var stableID: String {
            identity.bundleID
        }
    }

    private let identityResolver = ApplicationIdentityResolver()

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
            ) else {
                return nil
            }

            return ProcessRecord(
                audioObjectID: process.audioObjectID,
                pid: process.pid,
                identity: identity
            )
        }

        return Dictionary(grouping: records, by: \.stableID)
            .map { stableID, group in
                let identity = group[0].identity
                return AudioApp(
                    id: stableID,
                    bundleID: identity.bundleID,
                    name: identity.name,
                    icon: identity.icon,
                    processIDs: group.map(\.audioObjectID).sorted(),
                    processIdentifiers: group.map(\.pid).sorted()
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func activeProcessObjectIDs(for processID: pid_t) throws -> [AudioObjectID] {
        try activeProcesses()
            .filter { $0.pid == processID }
            .map(\.audioObjectID)
            .sorted()
    }

    private func activeProcesses() throws -> [ActiveProcess] {
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

            return ActiveProcess(
                audioObjectID: objectID,
                pid: pid,
                reportedBundleID: try? CoreAudioSupport.readString(
                    objectID: objectID,
                    selector: kAudioProcessPropertyBundleID,
                    operation: "Read audio process bundle ID"
                )
            )
        }
    }
}
