import CoreAudio
import Foundation
import OSLog

/// What Core Audio reported changing since the last delivered notification.
struct AudioChange: OptionSet {
    let rawValue: Int

    static let processList = AudioChange(rawValue: 1 << 0)
    static let defaultOutputDevice = AudioChange(rawValue: 1 << 1)
    static let processOutputState = AudioChange(rawValue: 1 << 2)
}

/// Watches Core Audio state changes without polling while the system is idle.
final class AudioActivityMonitor {
    /// How long to wait for a burst of related property changes to settle.
    static let coalescingInterval: TimeInterval = 0.15
    /// Ceiling on that wait. An output-device switch emits a stream of changes
    /// across all three property kinds; without a ceiling each one pushed
    /// delivery out again, so a sustained burst could postpone re-applying the
    /// user's volume indefinitely.
    static let maximumCoalescingDelay: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "com.dbdeck.audio-activity")
    private let queueKey = DispatchSpecificKey<Void>()
    private let onChange: (AudioChange) -> Void
    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "Energy")

    // One block per property kind, reused across every object it is registered
    // on: Core Audio matches listeners by block reference, so sharing one keeps
    // registration and removal symmetrical and avoids allocating a closure per
    // audio process object.
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var processOutputListener: AudioObjectPropertyListenerBlock?

    private var watchedProcessObjectIDs: Set<AudioObjectID> = []
    private var pendingNotification: DispatchWorkItem?
    private var pendingSince: Date?
    private var pendingChange: AudioChange = []

    init(onChange: @escaping (AudioChange) -> Void) throws {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())

        let processListListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.rebuildOutputListeners()
            self.recordChange(.processList)
        }
        self.processListListener = processListListener
        self.defaultOutputListener = { [weak self] _, _ in
            self?.recordChange(.defaultOutputDevice)
        }
        self.processOutputListener = { [weak self] _, _ in
            self?.recordChange(.processOutputState)
        }

        do {
            try CoreAudioSupport.check(
                CoreAudioSupport.addPropertyListener(
                    objectID: CoreAudioSupport.systemObject,
                    selector: kAudioHardwarePropertyProcessObjectList,
                    queue: queue,
                    listener: processListListener
                ),
                operation: "Watch audio process list"
            )
            try CoreAudioSupport.check(
                CoreAudioSupport.addPropertyListener(
                    objectID: CoreAudioSupport.systemObject,
                    selector: kAudioHardwarePropertyDefaultOutputDevice,
                    queue: queue,
                    listener: self.defaultOutputListener!
                ),
                operation: "Watch default output device"
            )
        } catch {
            onQueue { removeAllListeners() }
            throw error
        }

        onQueue { rebuildOutputListeners() }
    }

    deinit {
        onQueue {
            pendingNotification?.cancel()
            pendingNotification = nil
            removeAllListeners()
        }
    }

    /// A listener block holds a temporary strong reference while it runs, so the
    /// last release — and therefore `deinit` — can happen on `queue`. Dispatching
    /// synchronously onto a serial queue from itself deadlocks, so check first.
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    private func rebuildOutputListeners() {
        guard let processOutputListener else { return }

        let objectIDs: [AudioObjectID]
        do {
            objectIDs = try CoreAudioSupport.readObjectIDs(
                objectID: CoreAudioSupport.systemObject,
                selector: kAudioHardwarePropertyProcessObjectList,
                operation: "Read audio process list for monitoring"
            )
        } catch {
            logger.error("Could not update audio activity listeners: \(error.localizedDescription, privacy: .public)")
            return
        }

        let desiredIDs = Set(objectIDs)
        var watchedIDs = watchedProcessObjectIDs.intersection(desiredIDs)

        // Core Audio recycles object IDs. Leaving a vanished object registered
        // means a later process assigned the same ID gets a second listener
        // while the stale one is still live, so every change fires twice.
        for objectID in watchedProcessObjectIDs.subtracting(desiredIDs) {
            CoreAudioSupport.removePropertyListener(
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunningOutput,
                queue: queue,
                listener: processOutputListener
            )
        }

        for objectID in desiredIDs.subtracting(watchedProcessObjectIDs) {
            let status = CoreAudioSupport.addPropertyListener(
                objectID: objectID,
                selector: kAudioProcessPropertyIsRunningOutput,
                queue: queue,
                listener: processOutputListener
            )
            guard status == noErr else {
                logger.debug("Could not watch audio object \(objectID): \(status)")
                continue
            }
            watchedIDs.insert(objectID)
        }

        watchedProcessObjectIDs = watchedIDs
    }

    private func removeAllListeners() {
        if let processOutputListener {
            for objectID in watchedProcessObjectIDs {
                CoreAudioSupport.removePropertyListener(
                    objectID: objectID,
                    selector: kAudioProcessPropertyIsRunningOutput,
                    queue: queue,
                    listener: processOutputListener
                )
            }
        }
        watchedProcessObjectIDs = []

        if let processListListener {
            CoreAudioSupport.removePropertyListener(
                objectID: CoreAudioSupport.systemObject,
                selector: kAudioHardwarePropertyProcessObjectList,
                queue: queue,
                listener: processListListener
            )
        }
        if let defaultOutputListener {
            CoreAudioSupport.removePropertyListener(
                objectID: CoreAudioSupport.systemObject,
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                queue: queue,
                listener: defaultOutputListener
            )
        }
        processListListener = nil
        defaultOutputListener = nil
        processOutputListener = nil
    }

    /// Called only from listener blocks, so the pending state stays queue-confined.
    private func recordChange(_ change: AudioChange) {
        pendingChange.insert(change)

        let delay: TimeInterval
        if let pendingSince {
            delay = max(
                min(
                    Self.coalescingInterval,
                    Self.maximumCoalescingDelay - Date().timeIntervalSince(pendingSince)
                ),
                0
            )
        } else {
            pendingSince = Date()
            delay = Self.coalescingInterval
        }

        pendingNotification?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let change = self.pendingChange
            self.pendingChange = []
            self.pendingSince = nil
            DispatchQueue.main.async { self.onChange(change) }
        }
        pendingNotification = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
