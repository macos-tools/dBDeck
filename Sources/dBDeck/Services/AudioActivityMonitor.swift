import CoreAudio
import Foundation
import OSLog

/// Watches Core Audio state changes without polling while the system is idle.
final class AudioActivityMonitor {
    private let queue = DispatchQueue(label: "com.dbdeck.audio-activity")
    private let onChange: () -> Void
    private let logger = Logger(subsystem: "com.dbdeck.mac", category: "Energy")
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var outputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var pendingNotification: DispatchWorkItem?

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
    }

    private func scheduleChangeNotification() {
        pendingNotification?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async(execute: self.onChange)
        }
        pendingNotification = workItem
        queue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}
