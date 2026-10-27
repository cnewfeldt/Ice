//
//  MenuBarAllowList.swift
//  Ice
//

import Foundation
import OSLog

/// Access to the system's per-app "Allow in the Menu Bar" list on macOS 27.
///
/// macOS 27 draws every status item inside `MenuBarAgent`, and the only
/// supported way to keep an app's items off the bar is the per-app switch in
/// System Settings > Menu Bar. That switch is stored as `trackedApplications`
/// in Control Center's group container preferences, as a binary property list
/// holding a flattened dictionary: `[key, value, key, value, ...]`.
///
/// Each key identifies an app (`{"bundle": {"_0": id}}` or
/// `{"adhocBinary": {"_0": {"relative": url}}}`). Each value holds the app's
/// `location`, the `menuItemLocations` whose items belong to it, and
/// `isAllowed`. Ice only ever flips `isAllowed`; everything else is written
/// back exactly as it was read.
///
/// Writes go through CoreFoundation's container-aware preferences functions,
/// which notify `MenuBarAgent` immediately. Writing the file directly has no
/// effect until `MenuBarAgent` restarts. Reading the container requires Full
/// Disk Access.
enum MenuBarAllowList {
    /// An entry in the allow list.
    struct Entry {
        /// A stable identifier for the entry, derived from its location.
        let id: String

        /// The bundle identifier of the entry's app, if it has one.
        let bundleIdentifier: String?

        /// The executable URL of the entry's app, if it is not a bundle.
        let executableURL: URL?

        /// Bundle identifiers whose menu bar items belong to this entry.
        let itemBundleIdentifiers: [String]

        /// Executable paths whose menu bar items belong to this entry.
        let itemExecutablePaths: [String]

        /// A Boolean value that indicates whether the entry's items are
        /// allowed in the menu bar.
        let isAllowed: Bool

        /// Returns a Boolean value that indicates whether the given app's
        /// menu bar items belong to this entry.
        func owns(bundleIdentifier: String?, executablePath: String?) -> Bool {
            if let bundleIdentifier {
                for candidate in itemBundleIdentifiers {
                    // Helpers are sometimes listed with a team prefix,
                    // for example "86Z3GCJ4MF.com.noodlesoft.HazelHelper".
                    if candidate == bundleIdentifier || candidate.hasSuffix("." + bundleIdentifier) {
                        return true
                    }
                }
            }
            if let executablePath {
                return itemExecutablePaths.contains(executablePath)
            }
            return false
        }
    }

    /// An error that can occur while accessing the allow list.
    enum AllowListError: Error, CustomStringConvertible {
        case unavailable
        case unreadable
        case unexpectedFormat(String)
        case writeFailed

        var description: String {
            switch self {
            case .unavailable:
                "The system preferences functions needed to access the menu bar allow list are missing."
            case .unreadable:
                "The menu bar allow list could not be read. Ice needs Full Disk Access."
            case .unexpectedFormat(let detail):
                "The menu bar allow list has an unexpected format (\(detail)). Ice will not change it."
            case .writeFailed:
                "The menu bar allow list could not be saved."
            }
        }
    }

    private static let logger = Logger(category: "MenuBarAllowList")

    private static let applicationID = "group.com.apple.controlcenter" as CFString
    private static let key = "trackedApplications" as CFString

    private static var containerPath: CFString {
        (NSHomeDirectory() + "/Library/Group Containers/group.com.apple.controlcenter") as CFString
    }

    // MARK: Container-Aware Preferences

    private typealias CopyValueFunction = @convention(c) (
        CFString, CFString, CFString, CFString, CFString
    ) -> Unmanaged<CFPropertyList>?

    private typealias SetValueFunction = @convention(c) (
        CFString, CFPropertyList?, CFString, CFString, CFString, CFString
    ) -> Void

    private typealias SynchronizeFunction = @convention(c) (
        CFString, CFString, CFString, CFString
    ) -> DarwinBoolean

    private struct Functions {
        let copyValue: CopyValueFunction
        let setValue: SetValueFunction
        let synchronize: SynchronizeFunction
    }

    private static let functions: Functions? = {
        guard
            let handle = dlopen(nil, RTLD_NOW),
            let copyValue = dlsym(handle, "_CFPreferencesCopyValueWithContainer"),
            let setValue = dlsym(handle, "_CFPreferencesSetValueWithContainer"),
            let synchronize = dlsym(handle, "_CFPreferencesSynchronizeWithContainer")
        else {
            return nil
        }
        return Functions(
            copyValue: unsafeBitCast(copyValue, to: CopyValueFunction.self),
            setValue: unsafeBitCast(setValue, to: SetValueFunction.self),
            synchronize: unsafeBitCast(synchronize, to: SynchronizeFunction.self)
        )
    }()

    // MARK: Reading

    /// A Boolean value that indicates whether the allow list can be read.
    static var isReadable: Bool {
        (try? readRawList()) != nil
    }

    /// Reads the entries in the allow list.
    static func entries() throws -> [Entry] {
        let list = try readRawList()
        return try parseEntries(from: list)
    }

    /// Reads the raw, flattened list from the preferences.
    private static func readRawList() throws -> [Any] {
        guard let functions else {
            throw AllowListError.unavailable
        }
        let value = functions.copyValue(
            key,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
            containerPath
        )?.takeRetainedValue()
        guard let data = value as? Data else {
            throw AllowListError.unreadable
        }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let list = plist as? [Any] else {
            throw AllowListError.unexpectedFormat("not an array")
        }
        guard list.count.isMultiple(of: 2) else {
            throw AllowListError.unexpectedFormat("odd number of elements")
        }
        return list
    }

    /// Parses the entries in the given raw list, validating its shape.
    private static func parseEntries(from list: [Any]) throws -> [Entry] {
        var entries = [Entry]()
        for index in stride(from: 0, to: list.count, by: 2) {
            guard
                let location = list[index] as? [String: Any],
                let value = list[index + 1] as? [String: Any],
                let isAllowed = value["isAllowed"] as? Bool
            else {
                throw AllowListError.unexpectedFormat("entry \(index / 2)")
            }
            let itemLocations = value["menuItemLocations"] as? [[String: Any]] ?? []
            entries.append(
                Entry(
                    id: identifier(for: location),
                    bundleIdentifier: bundleIdentifier(in: location),
                    executableURL: executableURL(in: location),
                    itemBundleIdentifiers: itemLocations.compactMap(bundleIdentifier(in:)),
                    itemExecutablePaths: itemLocations.compactMap { executableURL(in: $0)?.path },
                    isAllowed: isAllowed
                )
            )
        }
        return entries
    }

    private static func bundleIdentifier(in location: [String: Any]) -> String? {
        (location["bundle"] as? [String: Any])?["_0"] as? String
    }

    private static func executableURL(in location: [String: Any]) -> URL? {
        guard
            let binary = (location["adhocBinary"] as? [String: Any])?["_0"] as? [String: Any],
            let relative = binary["relative"] as? String
        else {
            return nil
        }
        return URL(string: relative)
    }

    private static func identifier(for location: [String: Any]) -> String {
        if let bundleIdentifier = bundleIdentifier(in: location) {
            return "bundle:" + bundleIdentifier
        }
        if let url = executableURL(in: location) {
            return "binary:" + url.path
        }
        // Unknown location kinds still need a stable identifier. Sorted keys
        // keep it the same from one read to the next.
        let data = try? JSONSerialization.data(withJSONObject: location, options: [.sortedKeys])
        return "other:" + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "?")
    }

    // MARK: Writing

    /// Sets whether the entries with the given identifiers are allowed in the
    /// menu bar, and returns the identifiers that actually changed.
    ///
    /// Entries that are not found are ignored. The list is written only if
    /// something changed.
    @discardableResult
    static func setAllowed(_ isAllowed: Bool, for ids: Set<String>) throws -> Set<String> {
        guard !ids.isEmpty else {
            return []
        }
        guard let functions else {
            throw AllowListError.unavailable
        }

        var list = try readRawList()
        // Validate the whole list before changing any of it.
        _ = try parseEntries(from: list)

        var changed = Set<String>()
        for index in stride(from: 0, to: list.count, by: 2) {
            guard
                let location = list[index] as? [String: Any],
                var value = list[index + 1] as? [String: Any],
                let current = value["isAllowed"] as? Bool
            else {
                continue
            }
            let id = identifier(for: location)
            guard ids.contains(id), current != isAllowed else {
                continue
            }
            value["isAllowed"] = isAllowed
            list[index + 1] = value
            changed.insert(id)
        }

        guard !changed.isEmpty else {
            return []
        }

        let data = try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        functions.setValue(
            key,
            data as CFData,
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
            containerPath
        )
        let synchronized = functions.synchronize(
            applicationID,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
            containerPath
        )
        guard synchronized.boolValue else {
            throw AllowListError.writeFailed
        }

        logger.info("Set allowed=\(isAllowed, privacy: .public) for \(changed.sorted(), privacy: .public)")
        return changed
    }
}
