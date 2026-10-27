//
//  MenuBarAgentReader.swift
//  Ice
//

import ApplicationServices
import Cocoa

/// Reads the status items drawn by `MenuBarAgent` on macOS 27.
///
/// On macOS 27, status items are no longer windows. `MenuBarAgent` draws them
/// in one window per display, and exposes each one through Accessibility as a
/// slot whose child element lives in the process that owns the item.
enum MenuBarAgentReader {
    /// A status item drawn by `MenuBarAgent`.
    struct Item {
        /// The process that owns the item.
        let pid: pid_t

        /// The frame of the item's slot, in screen coordinates (top-left origin).
        let frame: CGRect

        /// The item's title, if it has one.
        let title: String?

        /// The slot's Accessibility element.
        let element: AXUIElement
    }

    /// The bundle identifier of `MenuBarAgent`.
    static let agentBundleIdentifier = "com.apple.MenuBarAgent"

    /// The description `MenuBarAgent` gives its overflow button.
    private static let overflowDescription = "Show Hidden Menu Bar Items"

    /// Returns the items currently listed by `MenuBarAgent`, across all displays.
    ///
    /// Items owned by `MenuBarAgent` itself (the clock, Wi-Fi, Control Center
    /// and other system items) are included, with `MenuBarAgent`'s process
    /// identifier.
    static func items() -> [Item] {
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleIdentifier).first else {
            return []
        }
        let application = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)

        var items = [Item]()
        for window in elements(of: application, attribute: kAXWindowsAttribute) {
            for slot in elements(of: window, attribute: kAXChildrenAttribute) {
                if string(of: slot, attribute: kAXDescriptionAttribute) == overflowDescription {
                    continue
                }
                guard
                    let child = elements(of: slot, attribute: kAXChildrenAttribute).first,
                    let frame = frame(of: slot),
                    frame.width > 0
                else {
                    continue
                }
                var pid: pid_t = 0
                guard AXUIElementGetPid(child, &pid) == .success else {
                    continue
                }
                let title = string(of: child, attribute: kAXTitleAttribute)
                    ?? string(of: child, attribute: kAXDescriptionAttribute)
                items.append(Item(pid: pid, frame: frame, title: title, element: slot))
            }
        }
        return items
    }

    /// Returns the process identifiers of the apps that have items in the menu bar.
    static func owningProcessIdentifiers() -> Set<pid_t> {
        Set(items().map { $0.pid })
    }

    // MARK: Accessibility Helpers

    private static func value(of element: AXUIElement, attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func elements(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        value(of: element, attribute: attribute) as? [AXUIElement] ?? []
    }

    private static func string(of element: AXUIElement, attribute: String) -> String? {
        guard let string = value(of: element, attribute: attribute) as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let value = value(of: element, attribute: "AXFrame"),
            CFGetTypeID(value) == AXValueGetTypeID()
        else {
            return nil
        }
        var frame = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &frame) else { // swiftlint:disable:this force_cast
            return nil
        }
        return frame
    }
}
