import Foundation
import IOKit

/// Small, leak-free helpers over the I/O Registry.
enum Registry {
    /// Runs `body` on every registered service of `className` (or a subclass), with its properties.
    static func each<T>(_ className: String, _ body: (io_registry_entry_t, [String: Any]) -> T?) -> [T] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        return collect(iterator) { body($0, properties(of: $0)) }
    }

    /// Runs `body` on each child of `entry` in the service plane that is a `className`.
    static func eachChild<T>(of entry: io_registry_entry_t, conformingTo className: String,
                             _ body: (io_registry_entry_t, [String: Any]) -> T?) -> [T] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        return collect(iterator) { child in
            IOObjectConformsTo(child, className) != 0 ? body(child, properties(of: child)) : nil
        }
    }

    private static func collect<T>(_ iterator: io_iterator_t, _ body: (io_registry_entry_t) -> T?) -> [T] {
        var results: [T] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let result = body(entry) { results.append(result) }
        }
        return results
    }

    static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else {
            return [:]
        }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    static func property(of entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// `key` on `entry`, or else on its nearest ancestor in the service plane that has it.
    static func inheritedProperty(of entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    static func name(of entry: io_registry_entry_t) -> String {
        var name = [CChar](repeating: 0, count: 128)   // io_name_t
        IORegistryEntryGetName(entry, &name)
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
