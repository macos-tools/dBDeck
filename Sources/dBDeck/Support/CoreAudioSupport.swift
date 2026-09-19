import CoreAudio
import Foundation

struct CoreAudioFailure: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        let localizedOperation = NSLocalizedString(
            operation,
            bundle: .main,
            comment: "Core Audio operation"
        )
        let format = NSLocalizedString(
            "%@ failed (%@)",
            bundle: .main,
            comment: "Core Audio failure with operation and status"
        )
        return String(
            format: format,
            locale: .current,
            localizedOperation,
            statusDescription
        )
    }

    private var statusDescription: String {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")'"
        }
        return String(status)
    }
}

enum CoreAudioSupport {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    @discardableResult
    static func addPropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) -> OSStatus {
        var propertyAddress = address(selector, scope: scope)
        return AudioObjectAddPropertyListenerBlock(objectID, &propertyAddress, queue, listener)
    }

    /// Core Audio matches a listener on address, queue and block, so removal has
    /// to be handed the same three values the registration used.
    static func removePropertyListener(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) {
        var propertyAddress = address(selector, scope: scope)
        AudioObjectRemovePropertyListenerBlock(objectID, &propertyAddress, queue, listener)
    }

    static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioFailure(operation: operation, status: status)
        }
    }

    static func readInteger<T: FixedWidthInteger>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T,
        operation: String
    ) throws -> T {
        var propertyAddress = address(selector, scope: scope)
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.stride)
        try check(
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &value),
            operation: operation
        )
        return value
    }

    static func readObjectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        operation: String
    ) throws -> [AudioObjectID] {
        var propertyAddress = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &size),
            operation: "\(operation) size"
        )
        guard size > 0 else { return [] }

        let stride = MemoryLayout<AudioObjectID>.stride
        var values = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / stride)
        guard !values.isEmpty else { return [] }

        try values.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw CoreAudioFailure(
                    operation: operation,
                    status: kAudioHardwareUnspecifiedError
                )
            }
            try check(
                AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, baseAddress),
                operation: operation
            )
        }
        // The read rewrites `size` with what was actually returned. The process
        // list changes constantly, so it can shrink between the two calls and
        // leave trailing kAudioObjectUnknown entries in the buffer.
        return Array(values.prefix(Int(size) / stride))
    }

    static func readString(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        operation: String
    ) throws -> String {
        var propertyAddress = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<CFString>.stride)
        var value: CFString = "" as CFString
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(
                AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, pointer),
                operation: operation
            )
        }
        return value as String
    }

    /// The stable identity of the current output device. Prefer this over the
    /// `AudioObjectID`, which Core Audio recycles: a device that disappears and
    /// is replaced can hand its old object ID to a different device.
    static func defaultOutputDeviceUID() throws -> String {
        let deviceID = try defaultOutputDeviceID()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioFailure(
                operation: "Find default output device",
                status: kAudioHardwareBadDeviceError
            )
        }
        return try readString(
            objectID: deviceID,
            selector: kAudioDevicePropertyDeviceUID,
            operation: "Read output device UID"
        )
    }

    private static func defaultOutputDeviceID() throws -> AudioObjectID {
        try readInteger(
            objectID: systemObject,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioObjectID(kAudioObjectUnknown),
            operation: "Read default output device"
        )
    }
}
