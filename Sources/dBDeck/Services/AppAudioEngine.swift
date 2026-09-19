import CoreAudio
import Foundation

/// Owns the set of live per-app audio routes and keeps it matching the volume
/// settings the store holds.
///
/// A route only exists for an app whose setting needs processing; an app left at
/// unmuted 100% is passed through untouched, which costs nothing and is why the
/// UI presents 100% as the cheap default.
protocol AppAudioRouting: AnyObject {
    /// Brings `app`'s route into line with `setting`, building, adjusting or
    /// tearing one down as needed.
    ///
    /// Returns a message describing why the application could not be routed, or
    /// `nil` if it is now playing as asked. A message means the application is
    /// audible at its own volume, so it is surfaced to the user rather than
    /// logged.
    func apply(_ setting: AppVolumeSetting, to app: AudioApp) -> String?

    /// Runs `body` with the current output device resolved once and shared by
    /// every `apply` inside it.
    func withOutputDeviceCached(_ body: () -> Void)

    /// Tears down everything held for applications outside `appIDs`, which is
    /// how a route ends when its application stops playing or quits.
    func retainOnly(appIDs: Set<String>)

    /// Brings one application's next attempt forward to now.
    func retryFailure(for appID: String)

    /// Brings every pending attempt forward to now.
    func retryFailures()

    /// Tears down every route, restoring normal output for all applications.
    func stopAll()
}

/// A live per-app audio route.
///
/// A route is identified by the two things it is built from: the set of audio
/// process objects it taps, and the output device it feeds. The device is held
/// as its UID string, which names one physical device for as long as it exists.
/// `AudioObjectID`s are handles Core Audio recycles, so a device that goes away
/// can pass its old ID to an unrelated one; identity has to survive that.
protocol AudioRoute: AnyObject {
    var processIDs: [AudioObjectID] { get }
    var outputDeviceUID: String { get }
    func setGain(_ gain: Float)
    func stop()
}

/// Builds routes through `ProcessAudioRoute` and keeps them in step with the
/// current settings and output device.
///
/// Every dependency on the outside world — reading the output device, building a
/// route, reading the clock — is injected, so the reconciliation and retry rules
/// below are exercised in tests without touching Core Audio.
final class AppAudioEngine: AppAudioRouting {
    /// A route that could not be built, and when to try again.
    ///
    /// Route setup fails transiently: Core Audio may still be settling an output
    /// device change, a device may be momentarily busy, a permission prompt may
    /// be pending. Because a failed route means the app plays untouched at full
    /// volume while its slider still shows the chosen level, a failure must
    /// never be terminal. Each one schedules the next attempt, doubling from
    /// `initialRetryInterval` to a `maximumRetryInterval` ceiling so a device
    /// that is genuinely unusable is not retried in a tight loop.
    private struct RouteFailure {
        let message: String
        let attempt: Int
        let nextAttemptAt: Date
    }

    /// How long to wait before the first re-attempt.
    static let initialRetryInterval: TimeInterval = 1
    /// The longest the wait grows to, however many attempts have failed.
    static let maximumRetryInterval: TimeInterval = 30

    // Keyed by application, which is also how the store keys settings, so a
    // route outlives the individual audio processes behind it.
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

        // An existing route can absorb a volume change in place. It cannot
        // absorb a different process set or a different device, since both are
        // fixed when the tap and aggregate device are created.
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

    /// Runs `body` with the current output device resolved once and shared by
    /// every `apply` inside it.
    ///
    /// A refresh pass applies settings for every playing app, and each would
    /// otherwise repeat the same two Core Audio property reads. The cache is
    /// scoped to this call so it cannot survive into a later pass, where the
    /// device may have changed.
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

    /// Brings this app's next attempt forward to now.
    ///
    /// Used when something happened that makes success newly likely — the user
    /// moved a slider or muted, or the output device changed — so the attempt
    /// is not held back by a delay earned under different conditions.
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
