import CoreAudio
import Foundation

protocol AppAudioRouting: AnyObject {
    func apply(_ setting: AppVolumeSetting, to app: AudioApp) -> String?
    func retainOnly(appIDs: Set<String>)
    func retryFailures()
    func stopAll()
}

final class AppAudioEngine: AppAudioRouting {
    private struct FailedConfiguration: Equatable {
        let processIDs: [AudioObjectID]
        let outputDeviceID: AudioObjectID
        let message: String
    }

    private var routes: [String: ProcessAudioRoute] = [:]
    private var failures: [String: FailedConfiguration] = [:]

    func apply(_ setting: AppVolumeSetting, to app: AudioApp) -> String? {
        let setting = setting.normalized
        guard setting.needsProcessing else {
            removeRoute(for: app.id)
            failures[app.id] = nil
            return nil
        }

        let defaultOutputID: AudioObjectID
        do {
            defaultOutputID = try CoreAudioSupport.defaultOutputDeviceID()
        } catch {
            return error.localizedDescription
        }

        if let route = routes[app.id],
           route.processIDs == app.processIDs.sorted(),
           route.outputDeviceID == defaultOutputID {
            route.setGain(setting.effectiveGain)
            failures[app.id] = nil
            return nil
        }

        removeRoute(for: app.id)
        if let failure = failures[app.id],
           failure.processIDs == app.processIDs.sorted(),
           failure.outputDeviceID == defaultOutputID {
            return failure.message
        }

        do {
            routes[app.id] = try ProcessAudioRoute(
                appID: app.id,
                processIDs: app.processIDs,
                gain: setting.effectiveGain
            )
            failures[app.id] = nil
            return nil
        } catch {
            let message = error.localizedDescription
            failures[app.id] = FailedConfiguration(
                processIDs: app.processIDs.sorted(),
                outputDeviceID: defaultOutputID,
                message: message
            )
            return message
        }
    }

    func retainOnly(appIDs: Set<String>) {
        for appID in routes.keys where !appIDs.contains(appID) {
            removeRoute(for: appID)
        }
        failures = failures.filter { appIDs.contains($0.key) }
    }

    func retryFailures() {
        failures.removeAll()
    }

    func stopAll() {
        for route in routes.values {
            route.stop()
        }
        routes.removeAll()
        failures.removeAll()
    }

    private func removeRoute(for appID: String) {
        routes.removeValue(forKey: appID)?.stop()
    }
}
