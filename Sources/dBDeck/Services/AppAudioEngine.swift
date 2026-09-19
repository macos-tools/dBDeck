import CoreAudio
import Foundation

protocol AppAudioRouting: AnyObject {
    func apply(_ setting: AppVolumeSetting, to app: AudioApp) -> String?
    func withOutputDeviceCached(_ body: () -> Void)
    func retainOnly(appIDs: Set<String>)
    func retryFailure(for appID: String)
    func retryFailures()
    func stopAll()
}

/// A live per-app audio route. Its identity is the process set it taps and the
/// output device UID it was built from — never an `AudioObjectID`, which Core
/// Audio recycles across devices.
protocol AudioRoute: AnyObject {
    var processIDs: [AudioObjectID] { get }
    var outputDeviceUID: String { get }
    func setGain(_ gain: Float)
    func stop()
}

final class AppAudioEngine: AppAudioRouting {
    /// Route setup can fail transiently — most often while Core Audio is still
    /// settling an output-device switch. Retrying on a widening schedule means
    /// such a failure cannot strand an app at full volume, which a permanently
    /// cached failure did: nothing short of the error banner's Retry button
    /// re-attempted, so neither a rescan nor moving the slider recovered.
    private struct RouteFailure {
        let message: String
        let attempt: Int
        let nextAttemptAt: Date
    }

    static let initialRetryInterval: TimeInterval = 1
    static let maximumRetryInterval: TimeInterval = 30

    private var routes: [String: AudioRoute] = [:]
    private var failures: [String: RouteFailure] = [:]

    private var isCachingOutputDevice = false
    private var cachedOutputDeviceUID: Result<String, Error>?

    private let currentOutputDeviceUID: () throws -> String
    private let makeRoute: (String, [AudioObjectID], Float) throws -> AudioRoute
    private let now: () -> Date

    init(
        currentOutputDeviceUID: @escaping () throws -> String =
            CoreAudioSupport.defaultOutputDeviceUID,
        makeRoute: @escaping (String, [AudioObjectID], Float) throws -> AudioRoute = {
            try ProcessAudioRoute(appID: $0, processIDs: $1, gain: $2)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.currentOutputDeviceUID = currentOutputDeviceUID
        self.makeRoute = makeRoute
        self.now = now
    }

    func apply(_ setting: AppVolumeSetting, to app: AudioApp) -> String? {
        guard setting.needsProcessing else {
            removeRoute(for: app.id)
            failures[app.id] = nil
            return nil
        }

        let outputDeviceUID: String
        do {
            outputDeviceUID = try resolvedOutputDeviceUID()
        } catch {
            return error.localizedDescription
        }

        let processIDs = app.processIDs.sorted()
        if let route = routes[app.id],
           route.processIDs == processIDs,
           route.outputDeviceUID == outputDeviceUID {
            route.setGain(setting.effectiveGain)
            failures[app.id] = nil
            return nil
        }

        removeRoute(for: app.id)
        if let failure = failures[app.id], now() < failure.nextAttemptAt {
            return failure.message
        }

        do {
            routes[app.id] = try makeRoute(app.id, processIDs, setting.effectiveGain)
            failures[app.id] = nil
            return nil
        } catch {
            let message = error.localizedDescription
            failures[app.id] = backingOff(from: failures[app.id], message: message)
            return message
        }
    }

    /// Reads the output device once for the duration of `body` rather than once
    /// per app. The cache cannot outlive the call, so it can never go stale.
    func withOutputDeviceCached(_ body: () -> Void) {
        isCachingOutputDevice = true
        defer {
            isCachingOutputDevice = false
            cachedOutputDeviceUID = nil
        }
        body()
    }

    private func resolvedOutputDeviceUID() throws -> String {
        if let cachedOutputDeviceUID {
            return try cachedOutputDeviceUID.get()
        }
        let result = Result { try currentOutputDeviceUID() }
        if isCachingOutputDevice {
            cachedOutputDeviceUID = result
        }
        return try result.get()
    }

    func retainOnly(appIDs: Set<String>) {
        for appID in Array(routes.keys) where !appIDs.contains(appID) {
            removeRoute(for: appID)
        }
        failures = failures.filter { appIDs.contains($0.key) }
    }

    /// Makes this app's next `apply` re-attempt immediately, for when the user
    /// asked for something directly (moving a slider, muting) and should not
    /// have to wait out a backoff.
    func retryFailure(for appID: String) {
        guard let failure = failures[appID] else { return }
        failures[appID] = RouteFailure(
            message: failure.message,
            attempt: failure.attempt,
            nextAttemptAt: .distantPast
        )
    }

    func retryFailures() {
        for appID in failures.keys {
            retryFailure(for: appID)
        }
    }

    func stopAll() {
        for route in routes.values {
            route.stop()
        }
        routes.removeAll()
        failures.removeAll()
    }

    private func backingOff(from previous: RouteFailure?, message: String) -> RouteFailure {
        let attempt = (previous?.attempt ?? 0) + 1
        let delay = min(
            Self.initialRetryInterval * pow(2, Double(attempt - 1)),
            Self.maximumRetryInterval
        )
        return RouteFailure(
            message: message,
            attempt: attempt,
            nextAttemptAt: now().addingTimeInterval(delay)
        )
    }

    private func removeRoute(for appID: String) {
        routes.removeValue(forKey: appID)?.stop()
    }
}
