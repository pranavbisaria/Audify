import CoreAudio
import Foundation

/// Thin, allocation-conscious wrappers over the `AudioObjectGetPropertyData` family.
///
/// Every call site in Audify goes through here so that error handling, scope defaults and
/// the `CFString` ownership rules live in exactly one place.
public enum CAError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)

    public var description: String {
        switch self {
        case let .osStatus(status, context):
            return "\(context) failed: \(Self.fourCC(status)) (\(status))"
        }
    }

    /// Core Audio reports most errors as packed four-character codes.
    public static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'" + String(decoding: bytes, as: UTF8.self) + "'"
        }
        return String(status)
    }
}

@inline(__always)
func checkStatus(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else { throw CAError.osStatus(status, context()) }
}

public struct CAProperty {
    public static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    @inline(__always)
    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func has(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(object, &addr)
    }

    public static func isSettable(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    public static func dataSize(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> UInt32 {
        var addr = address(selector, scope: scope, element: element)
        var size: UInt32 = 0
        try checkStatus(
            AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size),
            "AudioObjectGetPropertyDataSize(\(CAError.fourCC(OSStatus(bitPattern: selector))))"
        )
        return size
    }

    /// Reads a single fixed-layout value (`UInt32`, `Float32`, `pid_t`, `AudioStreamBasicDescription`, …).
    public static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T
    ) throws -> T {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        let scratch = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        scratch.initialize(to: defaultValue)
        try checkStatus(
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, scratch),
            "AudioObjectGetPropertyData(\(CAError.fourCC(OSStatus(bitPattern: selector))))"
        )
        return scratch.pointee
    }

    /// Reads a variable-length array of fixed-layout values.
    public static func array<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        of _: T.Type
    ) throws -> [T] {
        let byteCount = try dataSize(object, selector, scope: scope, element: element)
        let count = Int(byteCount) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        var addr = address(selector, scope: scope, element: element)
        var size = byteCount
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        try checkStatus(
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, buffer),
            "AudioObjectGetPropertyData(array \(CAError.fourCC(OSStatus(bitPattern: selector))))"
        )
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a `CFString` property. Core Audio hands over ownership, so we consume the +1 reference.
    public static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var raw: CFString?
        try checkStatus(
            withUnsafeMutablePointer(to: &raw) { pointer in
                AudioObjectGetPropertyData(object, &addr, 0, nil, &size, pointer)
            },
            "AudioObjectGetPropertyData(string \(CAError.fourCC(OSStatus(bitPattern: selector))))"
        )
        guard let raw else { return "" }
        return raw as String
    }

    public static func setValue<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        to newValue: T
    ) throws {
        var addr = address(selector, scope: scope, element: element)
        try withUnsafeBytes(of: newValue) { raw in
            try checkStatus(
                AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(raw.count), raw.baseAddress!),
                "AudioObjectSetPropertyData(\(CAError.fourCC(OSStatus(bitPattern: selector))))"
            )
        }
    }

    public static func setCFValue(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        to newValue: CFTypeRef
    ) throws {
        var addr = address(selector, scope: scope, element: element)
        let unmanaged = Unmanaged.passUnretained(newValue as AnyObject).toOpaque()
        try withUnsafeBytes(of: unmanaged) { raw in
            try checkStatus(
                AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(raw.count), raw.baseAddress!),
                "AudioObjectSetPropertyData(cf \(CAError.fourCC(OSStatus(bitPattern: selector))))"
            )
        }
    }
}

/// A registered Core Audio property listener that unsubscribes itself on `deinit`.
///
/// Audify never polls Core Audio; every piece of state is driven by one of these.
public final class CAPropertyObserver {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    public init(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) {
        self.object = object
        self.address = CAProperty.address(selector, scope: scope, element: element)
        self.queue = queue

        let listener: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        self.block = listener
        AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
    }

    deinit {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
