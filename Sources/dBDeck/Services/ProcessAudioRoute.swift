import AudioDSP
import CoreAudio
import Foundation
import OSLog

final class ProcessAudioRoute: AudioRoute {
    let appID: String
    let processIDs: [AudioObjectID]
    let outputDeviceUID: String

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var gainContext: UnsafeMutableRawPointer?
    private var isStopped = false
    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "Route")

    init(appID: String, processIDs: [AudioObjectID], gain: Float) throws {
        self.appID = appID
        self.processIDs = processIDs.sorted()
        outputDeviceUID = try CoreAudioSupport.defaultOutputDeviceUID()

        guard let context = DBDGainContextCreate(gain) else {
            throw CoreAudioFailure(operation: "Allocate audio gain state", status: OSStatus(memFullErr))
        }
        gainContext = context

        do {
            try start(gain: gain)
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func setGain(_ gain: Float) {
        guard let gainContext else { return }
        DBDGainContextSetGain(gainContext, gain)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true

        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        ioProcID = nil

        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        if let gainContext {
            DBDGainContextDestroy(gainContext)
            self.gainContext = nil
        }
    }

    private func start(gain: Float) throws {
        let tapDescription = CATapDescription(
            processes: processIDs,
            deviceUID: outputDeviceUID,
            stream: 0
        )
        tapDescription.name = "dBDeck \(appID)"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        try CoreAudioSupport.check(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "Create process audio tap"
        )

        let tapUID = try CoreAudioSupport.readString(
            objectID: tapID,
            selector: kAudioTapPropertyUID,
            operation: "Read process tap UID"
        )
        let aggregateUID = "com.dbdeck.route.\(UUID().uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "dBDeck Private Route",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID]
            ]
        ]

        try CoreAudioSupport.check(
            AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &aggregateDeviceID
            ),
            operation: "Create private aggregate audio device"
        )

        guard let gainContext else {
            throw CoreAudioFailure(operation: "Prepare audio callback", status: kAudioHardwareUnspecifiedError)
        }
        DBDGainContextSetGain(gainContext, gain)

        var newIOProcID: AudioDeviceIOProcID?
        try CoreAudioSupport.check(
            AudioDeviceCreateIOProcID(
                aggregateDeviceID,
                DBDGainAudioIOProc,
                gainContext,
                &newIOProcID
            ),
            operation: "Create audio processing callback"
        )
        ioProcID = newIOProcID

        logFormatMismatchIfNeeded()

        try CoreAudioSupport.check(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            operation: "Start per-app audio route"
        )
    }

    /// The gain callback pairs input and output buffers by index and copies the
    /// smaller byte count, which assumes the tap and the aggregate agree on
    /// channel layout. They should, because the tap is created against this
    /// device's stream. Log it rather than refuse the route if they ever differ,
    /// so a real mismatch leaves evidence instead of silently garbling audio.
    private func logFormatMismatchIfNeeded() {
        guard
            let tapFormat = streamFormat(of: tapID, selector: kAudioTapPropertyFormat),
            let deviceFormat = streamFormat(
                of: aggregateDeviceID,
                selector: kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeOutput
            ),
            tapFormat.mChannelsPerFrame != deviceFormat.mChannelsPerFrame
                || tapFormat.mSampleRate != deviceFormat.mSampleRate
        else {
            return
        }
        logger.warning(
            """
            Route \(self.appID, privacy: .public): tap format \
            \(tapFormat.mChannelsPerFrame) ch @ \(tapFormat.mSampleRate) Hz does not match \
            device format \(deviceFormat.mChannelsPerFrame) ch @ \(deviceFormat.mSampleRate) Hz
            """
        )
    }

    private func streamFormat(
        of objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioStreamBasicDescription? {
        var propertyAddress = CoreAudioSupport.address(selector, scope: scope)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &propertyAddress,
            0,
            nil,
            &size,
            &format
        )
        return status == noErr ? format : nil
    }
}
