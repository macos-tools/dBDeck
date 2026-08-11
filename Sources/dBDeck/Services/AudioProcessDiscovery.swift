import AppKit
import CoreAudio
import Foundation

struct AudioProcessDiscovery {
    private struct ProcessRecord {
        let audioObjectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let runningApplication: NSRunningApplication?

        var stableID: String {
            bundleID ?? "pid:\(pid)"
        }
    }

    func activeApps() throws -> [AudioApp] {
        let processObjectIDs = try CoreAudioSupport.readObjectIDs(
            objectID: CoreAudioSupport.systemObject,
            selector: kAudioHardwarePropertyProcessObjectList,
            operation: "Read audio process list"
        )

        let runningApplications = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map {
                ($0.processIdentifier, $0)
            }
        )

        let records = processObjectIDs.compactMap { objectID -> ProcessRecord? in
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

            let rawBundleID = try? CoreAudioSupport.readString(
                objectID: objectID,
                selector: kAudioProcessPropertyBundleID,
                operation: "Read audio process bundle ID"
            )
            let application = runningApplications[pid]
            let bundleID = [rawBundleID, application?.bundleIdentifier]
                .compactMap { $0 }
                .first { !$0.isEmpty }

            return ProcessRecord(
                audioObjectID: objectID,
                pid: pid,
                bundleID: bundleID,
                runningApplication: application
            )
        }

        return Dictionary(grouping: records, by: \.stableID)
            .map { stableID, group in
                let app = group.compactMap(\.runningApplication).first
                let fallbackName = group.first.map { processName(for: $0.pid) } ?? "Audio Process"
                return AudioApp(
                    id: stableID,
                    bundleID: group.compactMap(\.bundleID).first,
                    name: app?.localizedName ?? fallbackName,
                    icon: app?.icon,
                    processIDs: group.map(\.audioObjectID).sorted(),
                    processIdentifiers: group.map(\.pid).sorted()
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func processName(for pid: pid_t) -> String {
        let name = ProcessInfo.processInfo.processName
        guard pid != getpid() else { return name }
        return "Process \(pid)"
    }
}
