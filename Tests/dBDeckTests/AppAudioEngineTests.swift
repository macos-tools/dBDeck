import AppKit
import CoreAudio
import Foundation
import Testing
@testable import dBDeck

/// Covers how routes are reconciled against the current settings and output
/// device, and how failures are retried.
///
/// The engine's Core Audio dependencies are injected, so these run against stub
/// routes and a controlled clock with no audio hardware involved.
@Suite("App audio engine")
struct AppAudioEngineTests {
    @Test func reusesTheRouteWhileTheOutputDeviceIsUnchanged() {
        let environment = RouteEnvironment()
        let engine = environment.makeEngine()
        let app = audioApp(processIDs: [11])

        #expect(engine.apply(setting(0.5), to: app) == nil)
        #expect(environment.createCallCount == 1)

        #expect(engine.apply(setting(0.25), to: app) == nil)
        #expect(environment.createCallCount == 1)
        #expect(environment.createdRoutes.last?.gain == 0.25)
    }

    @Test func rebuildsTheRouteWhenTheOutputDeviceUIDChanges() {
        let environment = RouteEnvironment()
        let engine = environment.makeEngine()
        let app = audioApp(processIDs: [11])

        #expect(engine.apply(setting(0.5), to: app) == nil)
        let firstRoute = environment.createdRoutes[0]

        environment.outputDeviceUID = "device-B"
        #expect(engine.apply(setting(0.5), to: app) == nil)

        #expect(environment.createCallCount == 2)
        #expect(firstRoute.stopCallCount == 1)
        #expect(environment.createdRoutes[1].outputDeviceUID == "device-B")
    }

    /// A failure must never be terminal. While a route is down the application
    /// plays at full volume with its slider still showing the chosen level, so
    /// a transient error has to resolve itself without the user intervening.
    @Test func retriesATransientFailureOnceTheBackoffElapses() {
        let environment = RouteEnvironment()
        let engine = environment.makeEngine()
        let app = audioApp(processIDs: [11])
        environment.failureMessage = "device busy"

        #expect(engine.apply(setting(0.5), to: app) == "device busy")
        #expect(environment.createCallCount == 1)

        // Inside the delay the stored message is reported again and no
        // attempt is made.
        #expect(engine.apply(setting(0.5), to: app) == "device busy")
        #expect(environment.createCallCount == 1)

        environment.failureMessage = nil
        environment.advance(by: AppAudioEngine.initialRetryInterval)
        #expect(engine.apply(setting(0.5), to: app) == nil)
        #expect(environment.createCallCount == 2)
    }

    @Test func backoffWidensBetweenAttemptsAndIsCapped() {
        let environment = RouteEnvironment()
        let engine = environment.makeEngine()
        let app = audioApp(processIDs: [11])
        environment.failureMessage = "device busy"

        var expectedDelay = AppAudioEngine.initialRetryInterval
        var attempts = 1
        _ = engine.apply(setting(0.5), to: app)

        for _ in 0..<8 {
            // Just short of the deadline nothing should be attempted.
            environment.advance(by: expectedDelay - 0.01)
            _ = engine.apply(setting(0.5), to: app)
            #expect(environment.createCallCount == attempts)

            environment.advance(by: 0.01)
            _ = engine.apply(setting(0.5), to: app)
            attempts += 1
            #expect(environment.createCallCount == attempts)

            expectedDelay = min(expectedDelay * 2, AppAudioEngine.maximumRetryInterval)
        }

        #expect(expectedDelay == AppAudioEngine.maximumRetryInterval)
    }

    @Test func aDirectUserActionRetriesWithoutWaitingOutTheBackoff() {
        let environment = RouteEnvironment()
        let engine = environment.makeEngine()
        let app = audioApp(processIDs: [11])
        environment.failureMessage = "device busy"
        #expect(engine.apply(setting(0.5), to: app) == "device busy")

        environment.failureMessage = nil
        engine.retryFailure(for: app.id)

        #expect(engine.apply(setting(0.5), to: app) == nil)
        #expect(environment.createCallCount == 2)
    }

    @Test func passthroughTearsTheRouteDown() {
        let environment = RouteEnvironment()
        let engine = environment.makeEngine()
        let app = audioApp(processIDs: [11])
        #expect(engine.apply(setting(0.5), to: app) == nil)

        #expect(engine.apply(.passthrough, to: app) == nil)
        #expect(environment.createdRoutes[0].stopCallCount == 1)

        #expect(engine.apply(setting(0.5), to: app) == nil)
        #expect(environment.createCallCount == 2)
    }

    @Test func retainOnlyStopsRoutesForAppsThatLeft() {
        let environment = RouteEnvironment()
        let engine = environment.makeEngine()
        let kept = audioApp(bundleID: "com.example.kept", processIDs: [11])
        let dropped = audioApp(bundleID: "com.example.dropped", processIDs: [12])
        _ = engine.apply(setting(0.5), to: kept)
        _ = engine.apply(setting(0.5), to: dropped)

        engine.retainOnly(appIDs: [kept.id])

        #expect(environment.createdRoutes[0].stopCallCount == 0)
        #expect(environment.createdRoutes[1].stopCallCount == 1)
    }

    @Test func readsTheOutputDeviceOncePerPass() {
        let environment = RouteEnvironment()
        let engine = environment.makeEngine()
        let apps = (0..<3).map {
            audioApp(bundleID: "com.example.app\($0)", processIDs: [AudioObjectID($0 + 1)])
        }

        engine.withOutputDeviceCached {
            for app in apps {
                _ = engine.apply(setting(0.5), to: app)
            }
        }

        #expect(environment.createCallCount == 3)
        #expect(environment.outputDeviceLookupCount == 1)

        // Outside a pass each call resolves the device again, so the shared
        // value cannot be carried into a later pass.
        for app in apps {
            _ = engine.apply(setting(0.4), to: app)
        }
        #expect(environment.outputDeviceLookupCount == 4)
    }

    private func setting(_ volume: Double) -> AppVolumeSetting {
        AppVolumeSetting(volume: volume, isMuted: false)
    }

    private func audioApp(
        bundleID: String = "com.example.player",
        processIDs: [AudioObjectID]
    ) -> AudioApp {
        AudioApp(
            bundleID: bundleID,
            name: "Player",
            icon: NSImage(size: NSSize(width: 16, height: 16)),
            bundleURL: nil,
            processIDs: processIDs,
            isPlaying: true,
            isRunning: true
        )
    }
}

private struct StubRouteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class StubRoute: AudioRoute {
    let processIDs: [AudioObjectID]
    let outputDeviceUID: String
    private(set) var gain: Float
    private(set) var stopCallCount = 0

    init(processIDs: [AudioObjectID], outputDeviceUID: String, gain: Float) {
        self.processIDs = processIDs
        self.outputDeviceUID = outputDeviceUID
        self.gain = gain
    }

    func setGain(_ gain: Float) {
        self.gain = gain
    }

    func stop() {
        stopCallCount += 1
    }
}

private final class RouteEnvironment {
    var outputDeviceUID = "device-A"
    var failureMessage: String?
    private(set) var outputDeviceLookupCount = 0
    private(set) var createdRoutes: [StubRoute] = []
    private(set) var createCallCount = 0
    private var currentDate = Date(timeIntervalSince1970: 1_000)

    func advance(by interval: TimeInterval) {
        currentDate = currentDate.addingTimeInterval(interval)
    }

    func makeEngine() -> AppAudioEngine {
        AppAudioEngine(
            currentOutputDeviceUID: {
                self.outputDeviceLookupCount += 1
                return self.outputDeviceUID
            },
            makeRoute: { _, processIDs, gain in
                self.createCallCount += 1
                if let failureMessage = self.failureMessage {
                    throw StubRouteError(message: failureMessage)
                }
                let route = StubRoute(
                    processIDs: processIDs,
                    outputDeviceUID: self.outputDeviceUID,
                    gain: gain
                )
                self.createdRoutes.append(route)
                return route
            },
            now: { self.currentDate }
        )
    }
}
