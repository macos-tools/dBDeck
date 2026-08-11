import AudioDSP
import CoreAudio
import Foundation

final class ProcessAudioRoute {
    let appID: String
    let processIDs: [AudioObjectID]
    let outputDeviceID: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var gainContext: UnsafeMutableRawPointer?
    private var isStopped = false

    init(appID: String, processIDs: [AudioObjectID], gain: Float) throws {
        self.appID = appID
        self.processIDs = processIDs.sorted()
        outputDeviceID = try CoreAudioSupport.defaultOutputDeviceID()

        guard outputDeviceID != kAudioObjectUnknown else {
            throw CoreAudioFailure(operation: "Find default output device", status: kAudioHardwareBadDeviceError)
        }
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
        let outputUID = try CoreAudioSupport.readString(
            objectID: outputDeviceID,
            selector: kAudioDevicePropertyDeviceUID,
            operation: "Read output device UID"
        )

        let tapDescription = CATapDescription(
            processes: processIDs,
            deviceUID: outputUID,
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
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
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

        try CoreAudioSupport.check(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            operation: "Start per-app audio route"
        )
    }
}
