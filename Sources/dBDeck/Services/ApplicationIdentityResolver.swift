import AppKit
import Foundation

struct ApplicationIdentityResolver {
    func resolve(
        pid: pid_t,
        reportedBundleID: String?,
        runningApplications: [pid_t: NSRunningApplication]
    ) -> ApplicationIdentity? {
        if let application = runningApplications[pid],
           let identity = identity(for: application) {
            return identity
        }

        if let reportedBundleID, !reportedBundleID.isEmpty {
            if let application = NSRunningApplication
                .runningApplications(withBundleIdentifier: reportedBundleID)
                .first(where: { $0.activationPolicy != .prohibited }),
               let identity = identity(for: application) {
                return identity
            }

            if let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: reportedBundleID
            ), let identity = identity(forApplicationURL: applicationURL) {
                return identity
            }
        }

        return parentApplicationIdentity(
            for: pid,
            runningApplications: runningApplications
        )
    }

    private func identity(for application: NSRunningApplication) -> ApplicationIdentity? {
        guard application.activationPolicy != .prohibited else {
            return nil
        }

        if let bundleURL = application.bundleURL,
           let identity = identity(forApplicationURL: bundleURL) {
            return identity
        }

        guard
            let bundleID = application.bundleIdentifier,
            let name = application.localizedName,
            let icon = application.icon
        else {
            return nil
        }
        return ApplicationIdentity(
            bundleID: bundleID,
            name: name,
            icon: icon,
            bundleURL: application.bundleURL
        )
    }

    private func identity(forApplicationURL url: URL) -> ApplicationIdentity? {
        let applicationURL = outermostApplicationURL(containing: url)
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              let bundle = Bundle(url: applicationURL),
              let bundleID = bundle.bundleIdentifier
        else {
            return nil
        }

        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? applicationURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        return ApplicationIdentity(
            bundleID: bundleID,
            name: name,
            icon: icon,
            bundleURL: applicationURL
        )
    }

    private func outermostApplicationURL(containing url: URL) -> URL {
        var candidate = url.standardizedFileURL
        var current = candidate

        for _ in 0..<32 {
            if current.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                candidate = current
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path.count < current.path.count else { break }
            current = parent
        }
        return candidate
    }

    private func parentApplicationIdentity(
        for pid: pid_t,
        runningApplications: [pid_t: NSRunningApplication]
    ) -> ApplicationIdentity? {
        var currentPID = pid
        var visited = Set<pid_t>()

        for _ in 0..<8 {
            guard currentPID > 1, visited.insert(currentPID).inserted else {
                break
            }
            if let application = runningApplications[currentPID],
               let identity = identity(for: application) {
                return identity
            }
            guard let parentPID = parentProcessID(of: currentPID) else {
                break
            }
            currentPID = parentPID
        }
        return nil
    }

    private func parentProcessID(of pid: pid_t) -> pid_t? {
        var processInfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &processInfo, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride
        else {
            return nil
        }
        return processInfo.kp_eproc.e_ppid
    }
}
