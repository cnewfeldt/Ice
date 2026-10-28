//
//  NativeHidingManager.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

/// A Boolean value that indicates whether Ice is running on macOS 27 or later,
/// where menu bar items are hidden through the system's allow list instead of
/// by moving them off screen.
var usesNativeMenuBarHiding: Bool {
    if #available(macOS 27.0, *) { true } else { false }
}

/// Hides and shows apps' menu bar items on macOS 27 by switching their
/// "Allow in the Menu Bar" setting.
///
/// Each app is assigned to a section. When a section is hidden, its apps are
/// disallowed; when it is shown, they are allowed again. Hiding is per app,
/// not per item, because that is the granularity the system offers.
///
/// Every app Ice disallows is recorded in a journal before the change is
/// written. Ice allows them again when a section is shown, when it quits, and
/// at the next launch. It never changes an app the user turned off themselves.
@MainActor
final class NativeHidingManager: ObservableObject {
    /// A set of section assignments, chosen by which displays are connected.
    ///
    /// The allow list applies to the menu bar on every display at once, so
    /// a layout can't differ between displays. Instead, a laptop can use a
    /// more compact layout while its built-in display is the only one.
    enum LayoutProfile: String, CaseIterable, Identifiable {
        case withExternalDisplay
        case builtInDisplayOnly

        var id: Self { self }

        /// A string to show in the interface.
        var displayString: String {
            switch self {
            case .withExternalDisplay: "With External Display"
            case .builtInDisplayOnly: "Laptop Screen Only"
            }
        }

        /// A Boolean value that indicates whether this Mac has a built-in
        /// display that is currently on.
        static var hasBuiltInDisplay: Bool {
            NSScreen.screens.contains { CGDisplayIsBuiltin($0.displayID) != 0 }
        }

        /// The profile for the displays that are connected now.
        static var current: LayoutProfile {
            let screens = NSScreen.screens
            guard !screens.isEmpty, screens.allSatisfy({ CGDisplayIsBuiltin($0.displayID) != 0 }) else {
                return .withExternalDisplay
            }
            return .builtInDisplayOnly
        }
    }

    /// An app shown in the layout interface.
    struct ManagedApp: Identifiable, Equatable {
        /// The identifier of the app's allow list entry.
        let id: String

        /// The app's display name.
        let name: String

        /// The app's icon.
        let icon: NSImage?

        /// The section the app is assigned to in the profile being edited.
        let section: MenuBarSection.Name

        /// The section the app is assigned to in the profile in use.
        let activeSection: MenuBarSection.Name

        /// A Boolean value that indicates whether the user turned the app
        /// off in System Settings, outside of Ice.
        let isTurnedOffByUser: Bool

        /// A Boolean value that indicates whether the app is running, and so
        /// can have items in the menu bar.
        let isRunning: Bool

        /// A Boolean value that indicates whether the app has items in the
        /// menu bar, but macOS folded all of them behind the overflow button
        /// for lack of room.
        let isFolded: Bool
    }

    /// The apps that can be arranged, sorted by name.
    @Published private(set) var apps = [ManagedApp]()

    /// The layout profile in use, based on the connected displays.
    @Published private(set) var activeProfile = LayoutProfile.current

    /// The layout profile shown in the layout pane.
    @Published var editingProfile = LayoutProfile.current {
        didSet {
            if editingProfile != oldValue {
                refreshApps()
            }
        }
    }

    /// A description of the most recent error, if the last attempt to update
    /// the allow list failed.
    @Published private(set) var lastError: String?

    /// The logger for the manager.
    private let logger = Logger(category: "NativeHidingManager")

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Pending delayed reconciliations, scheduled after apps launch.
    private var delayedReconcileTasks = [Task<Void, Never>]()

    /// Allow list entries that are shown while their menu is open, even
    /// though their section is hidden.
    private var temporarilyShown = Set<String>()

    /// The task that opens an app's item from the Ice Bar.
    private var openItemTask: Task<Void, Never>?

    /// App names and icons, by allow list entry identifier. Loading icons
    /// from disk is slow enough to delay opening the Ice Bar.
    private var nameAndIconCache = [String: (name: String, icon: NSImage?)]()

    /// The identifier of Ice's own allow list entry, which is never disallowed.
    private var ownEntryID: String? {
        Bundle.main.bundleIdentifier.map { "bundle:" + $0 }
    }

    // MARK: Persistence

    private enum Keys {
        static let assignments = "MacOS27SectionAssignments"
        static let builtInDisplayAssignments = "MacOS27SectionAssignmentsBuiltInDisplay"
        static let journal = "MacOS27DisallowedByIce"
        static let order = "MacOS27AppOrder"
    }

    /// The section assigned to each allow list entry in the profile in use.
    private var assignments: [String: MenuBarSection.Name] {
        assignments(for: activeProfile)
    }

    private static func storageKey(for profile: LayoutProfile) -> String {
        switch profile {
        case .withExternalDisplay: Keys.assignments
        case .builtInDisplayOnly: Keys.builtInDisplayAssignments
        }
    }

    /// Returns the section assigned to each allow list entry in the given
    /// profile. Entries that are not listed are in the visible section.
    ///
    /// Until the laptop profile is first changed, it uses the same
    /// assignments as the external display profile.
    private func assignments(for profile: LayoutProfile) -> [String: MenuBarSection.Name] {
        let defaults = UserDefaults.standard
        let raw = defaults.dictionary(forKey: Self.storageKey(for: profile)) as? [String: String]
            ?? defaults.dictionary(forKey: Keys.assignments) as? [String: String]
            ?? [:]
        return raw.compactMapValues(MenuBarSection.Name.init(storageKey:))
    }

    private func setAssignments(_ assignments: [String: MenuBarSection.Name], for profile: LayoutProfile) {
        let raw = assignments.filter { $0.value != .visible }.mapValues(\.storageKey)
        UserDefaults.standard.set(raw, forKey: Self.storageKey(for: profile))
    }

    /// The allow list entries that Ice has disallowed and must allow again.
    private var journal: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.journal) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Keys.journal) }
    }

    /// The order the user arranged apps in. Apps that were never moved are
    /// not listed, and sort by name after the ones that were.
    private var order: [String] {
        get { UserDefaults.standard.stringArray(forKey: Keys.order) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.order) }
    }

    // MARK: Setup

    /// Performs the initial setup of the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables(with: appState)
        reconcile()
        refreshApps()
    }

    private func configureCancellables(with appState: AppState) {
        var c = Set<AnyCancellable>()

        // Sections are shown and hidden by changing their control items' states.
        Publishers.MergeMany(appState.menuBarManager.sections.map { $0.controlItem.$state.replace(with: ()) })
            .merge(with: appState.settings.advanced.$enableAlwaysHiddenSection.replace(with: ()))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.reconcile()
            }
            .store(in: &c)

        // An app MenuBarAgent has never seen has no allow list entry until its
        // first item appears, so check again a few times after a launch.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleDelayedReconciliation()
            }
            .store(in: &c)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshApps()
            }
            .store(in: &c)

        // Switch layouts when a display is connected or disconnected.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateActiveProfile()
            }
            .store(in: &c)

        Timer.publish(every: 15, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reconcile()
            }
            .store(in: &c)

        cancellables = c
    }

    private func updateActiveProfile() {
        let profile = LayoutProfile.current
        guard profile != activeProfile else {
            return
        }
        logger.info("Switching to layout profile \(profile.rawValue, privacy: .public)")
        activeProfile = profile
        editingProfile = profile
        reconcile()
        refreshApps()
    }

    private func scheduleDelayedReconciliation() {
        delayedReconcileTasks.forEach { $0.cancel() }
        delayedReconcileTasks = [1, 3, 8].map { seconds in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else {
                    return
                }
                self?.reconcile()
                self?.refreshApps()
            }
        }
    }

    // MARK: Hiding

    /// The allow list entries that should currently be disallowed, based on
    /// the assignments and the state of each section.
    private func entriesToHide() -> Set<String> {
        guard let menuBarManager = appState?.menuBarManager else {
            return []
        }
        // Use the control items' states rather than the sections' `isHidden`.
        // With the Ice Bar, a shown section is displayed in the panel and its
        // control item stays hidden, so its apps must stay out of the bar.
        let hiddenIsHidden = menuBarManager.controlItem(withName: .hidden)?.state != .showSection
        let alwaysHiddenSection = menuBarManager.section(withName: .alwaysHidden)
        let alwaysHiddenIsHidden = alwaysHiddenSection?.controlItem.state != .showSection
        let alwaysHiddenEnabled = alwaysHiddenSection?.isEnabled ?? false

        var result = Set<String>()
        for (id, section) in assignments {
            let isHidden = switch section {
            case .visible:
                false
            case .hidden:
                hiddenIsHidden
            case .alwaysHidden where alwaysHiddenEnabled:
                alwaysHiddenIsHidden
            case .alwaysHidden:
                // Without an always-hidden section, its apps follow the hidden section.
                hiddenIsHidden
            }
            if isHidden {
                result.insert(id)
            }
        }
        result.subtract(temporarilyShown)
        if let ownEntryID {
            result.remove(ownEntryID)
        }
        return result
    }

    /// Brings the allow list in line with the sections' current states.
    func reconcile() {
        do {
            let entries = try MenuBarAllowList.entries()
            let toHide = entriesToHide()

            let hide = Set(entries.filter { toHide.contains($0.id) && $0.isAllowed }.map(\.id))
            // Only ever allow entries that Ice itself disallowed.
            let show = Set(entries.filter { journal.contains($0.id) && !toHide.contains($0.id) && !$0.isAllowed }.map(\.id))

            if !hide.isEmpty {
                // Record before writing, so a crash mid-write still gets restored.
                journal.formUnion(hide)
                try MenuBarAllowList.setAllowed(false, for: hide)
            }
            if !show.isEmpty {
                try MenuBarAllowList.setAllowed(true, for: show)
            }

            // Forget journal entries that are allowed now (shown by Ice, or
            // turned back on by the user) and are not meant to be hidden, and
            // entries that no longer exist.
            let allowedIDs = Set(entries.filter(\.isAllowed).map(\.id)).union(show)
            let existingIDs = Set(entries.map(\.id))
            journal = journal.filter { id in
                existingIDs.contains(id) && (toHide.contains(id) || !allowedIDs.contains(id))
            }

            lastError = nil
        } catch {
            logger.error("Error updating menu bar allow list: \(error, privacy: .public)")
            lastError = String(describing: error)
        }
    }

    /// Allows every app that Ice disallowed. Called before Ice quits.
    func restoreAll() {
        let ids = journal
        guard !ids.isEmpty else {
            return
        }
        do {
            try MenuBarAllowList.setAllowed(true, for: ids)
            journal = []
            logger.info("Restored \(ids.count) apps to the menu bar")
        } catch {
            logger.error("Error restoring menu bar allow list: \(error, privacy: .public)")
        }
    }

    // MARK: Opening Items

    /// Shows the app with the given entry identifier in the menu bar and
    /// opens its item, as if the user clicked it.
    ///
    /// The app is shown only while its menu is open. If the menu bar has no
    /// room to draw the item, macOS folds it behind the overflow button, where
    /// it cannot be pressed directly, so the overflow menu is opened instead.
    func openItem(for id: String) {
        openItemTask?.cancel()
        openItemTask = Task { [weak self] in
            guard let self else {
                return
            }
            await openItemAndWait(for: id)
            temporarilyShown.remove(id)
            reconcile()
        }
    }

    private func openItemAndWait(for id: String) async {
        guard let entry = try? MenuBarAllowList.entries().first(where: { $0.id == id }) else {
            logger.error("Cannot open item: no allow list entry for \(id, privacy: .public)")
            return
        }

        let pids = Set(
            NSWorkspace.shared.runningApplications
                .filter { entry.owns(bundleIdentifier: $0.bundleIdentifier, executablePath: $0.executableURL?.path) }
                .map(\.processIdentifier)
        )
        guard !pids.isEmpty else {
            logger.info("Cannot open item: \(id, privacy: .public) is not running")
            return
        }

        temporarilyShown.insert(id)
        reconcile()

        // MenuBarAgent fades a newly allowed item in over about a quarter of
        // a second, and lists it as folded until it settles.
        var snapshot = MenuBarAgentReader.snapshot()
        var drawnItem: MenuBarAgentReader.Item?
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else {
                return
            }
            snapshot = MenuBarAgentReader.snapshot()
            if let item = snapshot.items.first(where: { pids.contains($0.pid) && snapshot.isDrawn($0) }) {
                drawnItem = item
                break
            }
        }

        var watchedPIDs = pids
        if let drawnItem {
            // The press reports an error even when the item opens, so the
            // result says nothing useful.
            AXUIElementPerformAction(drawnItem.element, kAXPressAction as CFString)
        } else if let overflowButton = snapshot.overflowButtons.first {
            logger.info("\(id, privacy: .public) is folded behind the overflow button; opening the overflow menu")
            AXUIElementPerformAction(overflowButton.element, kAXPressAction as CFString)
            if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarAgentReader.agentBundleIdentifier).first {
                watchedPIDs.insert(agent.processIdentifier)
            }
        } else {
            logger.error("Cannot open item: \(id, privacy: .public) did not appear in the menu bar")
            return
        }

        await waitForMenusToClose(ownedBy: watchedPIDs)
    }

    /// Waits until the given processes have no menus or popovers on screen.
    ///
    /// Status items are not windows on macOS 27, so any on-screen window
    /// above the normal level that belongs to these processes is a menu,
    /// popover or panel opened from the menu bar. MenuBarAgent's own bar
    /// windows are excluded by their height.
    private func waitForMenusToClose(ownedBy pids: Set<pid_t>) async {
        func hasOpenMenu() -> Bool {
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[CFString: Any]] else {
                return false
            }
            return windows.contains { window in
                guard
                    let pid = window[kCGWindowOwnerPID] as? pid_t,
                    pids.contains(pid),
                    let layer = window[kCGWindowLayer] as? Int,
                    layer > 0,
                    let bounds = window[kCGWindowBounds] as? [String: CGFloat],
                    let height = bounds["Height"]
                else {
                    return false
                }
                return height > 40
            }
        }

        // Give the menu time to open. If it never does, keep the app shown
        // briefly so a slow app still has a chance, then give up.
        var sawMenu = false
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            if hasOpenMenu() {
                sawMenu = true
                break
            }
        }
        guard sawMenu else {
            return
        }

        // Wait for the menu to close, requiring it to stay closed briefly so
        // a menu replaced by a submenu or a second popover is not mistaken
        // for a closed one. Give up after ten minutes.
        var closedSince: Date?
        for _ in 0..<2400 {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            if hasOpenMenu() {
                closedSince = nil
            } else if let closedSince {
                if Date.now.timeIntervalSince(closedSince) >= 0.75 {
                    return
                }
            } else {
                closedSince = .now
            }
        }
    }

    // MARK: Layout

    /// Assigns the app with the given entry identifier to a section.
    func assign(_ id: String, to section: MenuBarSection.Name) {
        guard id != ownEntryID else {
            return
        }
        var newAssignments = assignments(for: editingProfile)
        newAssignments[id] = section
        setAssignments(newAssignments, for: editingProfile)
        reconcile()
        refreshApps()
    }

    /// Moves every visible app that macOS folded behind the overflow button
    /// into the hidden section of the layout in use, where the Ice Bar can
    /// show it.
    func moveFoldedAppsToHidden() {
        let ids = apps.filter { $0.activeSection == .visible && $0.isFolded }.map(\.id)
        guard !ids.isEmpty else {
            return
        }
        var newAssignments = assignments(for: activeProfile)
        for id in ids where id != ownEntryID {
            newAssignments[id] = .hidden
        }
        setAssignments(newAssignments, for: activeProfile)
        logger.info("Moved \(ids.count) folded apps to the hidden section")
        reconcile()
        refreshApps()
    }

    /// Moves the app with the given entry identifier into a section, placing
    /// it before another app, or at the end of the section if `target` is `nil`.
    ///
    /// The order is used by the layout pane and the Ice Bar. It does not
    /// change the order of items in the menu bar, which macOS 27 does not
    /// let apps change.
    func move(_ id: String, before target: String?, in section: MenuBarSection.Name) {
        guard id != ownEntryID, id != target else {
            return
        }

        // Start from the order currently displayed, so apps that were never
        // moved keep their place relative to the moved one.
        var newOrder = apps.map(\.id).filter { $0 != id }
        if let target, let index = newOrder.firstIndex(of: target) {
            newOrder.insert(id, at: index)
        } else if let lastInSection = apps.last(where: { $0.section == section && $0.id != id }),
                  let index = newOrder.firstIndex(of: lastInSection.id) {
            newOrder.insert(id, at: index + 1)
        } else {
            newOrder.append(id)
        }
        // Keep the positions of apps that aren't listed right now.
        let listed = Set(newOrder)
        order = newOrder + order.filter { !listed.contains($0) && $0 != id }

        if (assignments(for: editingProfile)[id] ?? .visible) != section {
            assign(id, to: section)
        } else {
            refreshApps()
        }
    }

    /// Updates the list of apps shown in the layout interface.
    ///
    /// Lists the apps that have items in the menu bar now, plus every app that
    /// is assigned to a hidden section or was hidden by Ice, since those are
    /// not drawn.
    func refreshApps() {
        guard let entries = try? MenuBarAllowList.entries() else {
            apps = []
            return
        }

        let editingAssignments = assignments(for: editingProfile)
        let activeAssignments = assignments
        let allAssignedIDs = LayoutProfile.allCases.reduce(into: Set<String>()) { ids, profile in
            ids.formUnion(assignments(for: profile).keys)
        }
        let journal = journal
        let ownEntryID = ownEntryID
        let positions = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        let runningApps = NSWorkspace.shared.runningApplications.map { app in
            (bundleIdentifier: app.bundleIdentifier, executablePath: app.executableURL?.path)
        }

        // The bar of the primary display, whose frame starts at the origin of
        // the global coordinate space that MenuBarAgent reports frames in.
        let primaryDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let snapshot = MenuBarAgentReader.snapshot()

        var ids = allAssignedIDs.union(journal)
        // The leftmost drawn position of each app's items in the menu bar.
        var barPositions = [String: CGFloat]()
        // Apps with at least one item listed, and with at least one drawn.
        var listedIDs = Set<String>()
        var drawnIDs = Set<String>()
        for item in snapshot.items {
            guard let app = NSRunningApplication(processIdentifier: item.pid) else {
                continue
            }
            let bundleIdentifier = app.bundleIdentifier
            let executablePath = app.executableURL?.path
            guard let entry = entries.first(where: { $0.owns(bundleIdentifier: bundleIdentifier, executablePath: executablePath) }) else {
                continue
            }
            ids.insert(entry.id)
            listedIDs.insert(entry.id)
            if snapshot.isDrawn(item) {
                drawnIDs.insert(entry.id)
            }
            if snapshot.isDrawn(item), primaryDisplayBounds.intersects(item.frame) {
                barPositions[entry.id] = min(barPositions[entry.id] ?? .infinity, item.frame.minX)
            }
        }

        apps = entries
            .filter { ids.contains($0.id) && $0.id != ownEntryID }
            .map { entry in
                let (name, icon) = cachedNameAndIcon(for: entry)
                return ManagedApp(
                    id: entry.id,
                    name: name,
                    icon: icon,
                    section: editingAssignments[entry.id] ?? .visible,
                    activeSection: activeAssignments[entry.id] ?? .visible,
                    isTurnedOffByUser: !entry.isAllowed && !journal.contains(entry.id),
                    isRunning: runningApps.contains { entry.owns(bundleIdentifier: $0.bundleIdentifier, executablePath: $0.executablePath) },
                    isFolded: listedIDs.contains(entry.id) && !drawnIDs.contains(entry.id)
                )
            }
            .sorted { lhs, rhs in
                // Group by section first, so each section's own ordering rule
                // only ever compares apps in that section.
                let sectionOrder = MenuBarSection.Name.allCases
                if lhs.section != rhs.section {
                    return sectionOrder.firstIndex(of: lhs.section) ?? 0 < sectionOrder.firstIndex(of: rhs.section) ?? 0
                }
                // Visible apps are listed in the order they're drawn in the
                // menu bar, followed by those folded behind the overflow button.
                if lhs.section == .visible {
                    switch (barPositions[lhs.id], barPositions[rhs.id]) {
                    case let (lhsPosition?, rhsPosition?):
                        return lhsPosition < rhsPosition
                    case (.some, nil):
                        return true
                    case (nil, .some):
                        return false
                    case (nil, nil):
                        break
                    }
                }
                return switch (positions[lhs.id], positions[rhs.id]) {
                case let (lhsPosition?, rhsPosition?):
                    lhsPosition < rhsPosition
                case (.some, nil):
                    true
                case (nil, .some):
                    false
                case (nil, nil):
                    lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            }
    }

    private func cachedNameAndIcon(for entry: MenuBarAllowList.Entry) -> (name: String, icon: NSImage?) {
        if let cached = nameAndIconCache[entry.id] {
            return cached
        }
        let result = Self.nameAndIcon(for: entry)
        nameAndIconCache[entry.id] = result
        return result
    }

    private static func nameAndIcon(for entry: MenuBarAllowList.Entry) -> (name: String, icon: NSImage?) {
        let fileManager = FileManager.default
        if
            let bundleIdentifier = entry.bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        {
            let name = fileManager.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return (name, NSWorkspace.shared.icon(forFile: url.path))
        }
        if let url = entry.executableURL {
            // Use the enclosing app bundle, if there is one.
            var bundleURL = url
            while bundleURL.pathComponents.count > 1, bundleURL.pathExtension != "app" {
                bundleURL.deleteLastPathComponent()
            }
            let iconURL = bundleURL.pathExtension == "app" ? bundleURL : url
            let name = iconURL.deletingPathExtension().lastPathComponent
            return (name, NSWorkspace.shared.icon(forFile: iconURL.path))
        }
        return (entry.bundleIdentifier ?? entry.id, nil)
    }
}

// MARK: - MenuBarSection.Name Storage

extension MenuBarSection.Name {
    /// The string used to store the section name.
    var storageKey: String {
        switch self {
        case .visible: "visible"
        case .hidden: "hidden"
        case .alwaysHidden: "alwaysHidden"
        }
    }

    /// Creates a section name from a stored string.
    init?(storageKey: String) {
        switch storageKey {
        case "visible": self = .visible
        case "hidden": self = .hidden
        case "alwaysHidden": self = .alwaysHidden
        default: return nil
        }
    }
}
