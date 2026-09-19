import CoreAudio
import Foundation
import OSLog

/// Watches Core Audio state changes without polling while the system is idle.
final class AudioActivityMonitor {
    /// How long to wait for a burst of related property changes to settle.
    static let coalescingInterval: TimeInterval = 0.15
    /// Ceiling on that wait. An output-device switch emits a stream of changes
    /// across three property kinds; without a ceiling each one pushed delivery
    /// out again, so a sustained burst could postpone re-applying the user's
    /// volume indefinitely.
    static let maximumCoalescingDelay: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "com.dbdeck.audio-activity")
    private let onChange: () -> Void
    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "Energy")
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var outputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var pendingNotification: DispatchWorkItem?
    private var pendingSince: Date?

    init(onChange: @escaping () -> Void) throws {
        self.onChange = onChange

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.rebuildOutputListeners()
            self.scheduleChangeNotification()
        }
        processListListener = listener

        var address = CoreAudioSupport.address(kAudioHardwarePropertyProcessObjectList)
        try CoreAudioSupport.check(
            AudioObjectAddPropertyListenerBlock(
                CoreAudioSupport.systemObject,
                &address,
                queue,
                listener
            ),
            operation: "Watch audio process list"
        )

        let outputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleChangeNotification()
        }
        defaultOutputListener = outputListener
        var outputAddress = CoreAudioSupport.address(
            kAudioHardwarePropertyDefaultOutputDevice
        )
        do {
            try CoreAudioSupport.check(
                AudioObjectAddPropertyListenerBlock(
                    CoreAudioSupport.systemObject,
                    &outputAddress,
                    queue,
                    outputListener
                ),
                operation: "Watch default output device"
            )
        } catch {
            queue.sync { removeAllListeners() }
            throw error
        }

        queue.sync {
            rebuildOutputListeners()
        }
    }

    deinit {
        pendingNotification?.cancel()
        queue.sync {
            removeAllListeners()
        }
    }

    private func rebuildOutputListeners() {
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
        for objectID in Array(outputListeners.keys) where !desiredIDs.contains(objectID) {
            // Core Audio has already destroyed objects removed from this list.
            // It also releases their listener blocks, so only drop our copy here.
            outputListeners[objectID] = nil
        }
        for objectID in desiredIDs where outputListeners[objectID] == nil {
            addOutputListener(for: objectID)
        }
    }

    private func addOutputListener(for objectID: AudioObjectID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleChangeNotification()
        }
        var address = CoreAudioSupport.address(kAudioProcessPropertyIsRunningOutput)
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, queue, listener)
        guard status == noErr else {
            logger.debug("Could not watch audio object \(objectID): \(status)")
            return
        }
        outputListeners[objectID] = listener
    }

    private func removeOutputListener(for objectID: AudioObjectID) {
        guard let listener = outputListeners.removeValue(forKey: objectID) else { return }
        var address = CoreAudioSupport.address(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, listener)
    }

    private func removeAllListeners() {
        for objectID in Array(outputListeners.keys) {
            removeOutputListener(for: objectID)
        }
        if let processListListener {
            var address = CoreAudioSupport.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(
                CoreAudioSupport.systemObject,
                &address,
                queue,
                processListListener
            )
        }
        processListListener = nil
        if let defaultOutputListener {
            var address = CoreAudioSupport.address(
                kAudioHardwarePropertyDefaultOutputDevice
            )
            AudioObjectRemovePropertyListenerBlock(
                CoreAudioSupport.systemObject,
                &address,
                queue,
                defaultOutputListener
            )
        }
        defaultOutputListener = nil
    }

    /// Called only from listener blocks, so `pendingSince` stays queue-confined.
    private func scheduleChangeNotification() {
        let delay: TimeInterval
        if let pendingSince {
            let alreadyWaited = Date().timeIntervalSince(pendingSince)
            delay = max(
                min(Self.coalescingInterval, Self.maximumCoalescingDelay - alreadyWaited),
                0
            )
        } else {
            pendingSince = Date()
            delay = Self.coalescingInterval
        }

        pendingNotification?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSince = nil
            DispatchQueue.main.async(execute: self.onChange)
        }
        pendingNotification = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
