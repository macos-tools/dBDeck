import CoreAudio
import Foundation
import OSLog

/// The kinds of Core Audio change a notification covers.
///
/// Several can arrive together, because one user action — switching the output
/// device, say — moves more than one property at a time.
struct AudioChange: OptionSet {
    let rawValue: Int

    static let processList = AudioChange(rawValue: 1 << 0)
    static let defaultOutputDevice = AudioChange(rawValue: 1 << 1)
    static let processOutputState = AudioChange(rawValue: 1 << 2)
}

/// Tells the store when Core Audio state has moved, so nothing has to be polled
/// while the machine is idle.
///
/// Three properties are watched: the list of audio processes, the default output
/// device, and each process's output-running flag. The first is watched on the
/// system object and drives registration of the third, which has to be attached
/// per process object as processes come and go.
///
/// Every listener runs on one serial queue, which owns all the mutable state
/// here. Notifications are coalesced before being delivered on the main queue:
/// a single user action can move several properties at once, and the store's
/// response to any of them is the same reconciliation pass.
final class AudioActivityMonitor {
    /// How long a burst of property changes is given to settle before delivery.
    static let coalescingInterval: TimeInterval = 0.15
    /// The longest delivery can be held once a burst has started.
    ///
    /// Each new change restarts the settle window, so a steady stream of them —
    /// an app churning audio processes, a device enumerating — would keep
    /// pushing delivery further out. The ceiling bounds how long the store can
    /// be left acting on stale state.
    static let maximumCoalescingDelay: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "com.dbdeck.audio-activity")
    private let queueKey = DispatchSpecificKey<Void>()
    private let onChange: (AudioChange) -> Void
    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "Energy")

    // Core Audio identifies a listener by the address, queue and block it was
    // registered with, so unregistering needs the same block reference back.
    // Holding one block per property kind keeps that symmetric however many
    // objects it is attached to.
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

        // Attaching the per-process listeners is the slow part of setup and
        // nothing observes its completion, so it runs behind the queue that
        // will own them.
        queue.async { [weak self] in
            self?.rebuildOutputListeners()
        }
    }

    deinit {
        onQueue {
            pendingNotification?.cancel()
            pendingNotification = nil
            removeAllListeners()
        }
    }

    /// Runs `body` with exclusive access to the queue-owned state.
    ///
    /// A listener block takes a strong reference for as long as it runs, so the
    /// final release — and with it `deinit` — can happen on `queue` itself.
    /// Dispatching synchronously onto a serial queue from that queue would never
    /// return, so the call is made directly when already there.
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

        // Object IDs are recycled, so a registration left behind for a process
        // that has gone will still be live when its ID is handed to a new one.
        // Unregistering as the list shrinks keeps one listener per object.
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

    /// Folds a change into the pending set and schedules its delivery.
    ///
    /// Only listener blocks call this, which is what confines the pending state
    /// to the queue.
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
