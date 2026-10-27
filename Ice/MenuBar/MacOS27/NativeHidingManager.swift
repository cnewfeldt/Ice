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
    /// An app shown in the layout interface.
    struct ManagedApp: Identifiable, Equatable {
        /// The identifier of the app's allow list entry.
        let id: String

        /// The app's display name.
        let name: String

        /// The app's icon.
        let icon: NSImage?

        /// The section the app is assigned to.
        let section: MenuBarSection.Name

        /// A Boolean value that indicates whether the user turned the app
        /// off in System Settings, outside of Ice.
        let isTurnedOffByUser: Bool
    }

    /// The apps that can be arranged, sorted by name.
    @Published private(set) var apps = [ManagedApp]()

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

    /// The identifier of Ice's own allow list entry, which is never disallowed.
    private var ownEntryID: String? {
        Bundle.main.bundleIdentifier.map { "bundle:" + $0 }
    }

    // MARK: Persistence

    private enum Keys {
        static let assignments = "MacOS27SectionAssignments"
        static let journal = "MacOS27DisallowedByIce"
    }

    /// The section assigned to each allow list entry. Entries that are not
    /// listed are in the visible section.
    private var assignments: [String: MenuBarSection.Name] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: Keys.assignments) as? [String: String] ?? [:]
            return raw.compactMapValues(MenuBarSection.Name.init(storageKey:))
        }
        set {
            let raw = newValue.filter { $0.value != .visible }.mapValues(\.storageKey)
            UserDefaults.standard.set(raw, forKey: Keys.assignments)
        }
    }

    /// The allow list entries that Ice has disallowed and must allow again.
    private var journal: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Keys.journal) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Keys.journal) }
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

        Timer.publish(every: 15, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.reconcile()
            }
            .store(in: &c)

        cancellables = c
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
        let hiddenSection = menuBarManager.section(withName: .hidden)
        let alwaysHiddenSection = menuBarManager.section(withName: .alwaysHidden)
        let alwaysHiddenEnabled = alwaysHiddenSection?.isEnabled ?? false

        var result = Set<String>()
        for (id, section) in assignments {
            let isHidden = switch section {
            case .visible:
                false
            case .hidden:
                hiddenSection?.isHidden ?? false
            case .alwaysHidden where alwaysHiddenEnabled:
                alwaysHiddenSection?.isHidden ?? false
            case .alwaysHidden:
                // Without an always-hidden section, its apps follow the hidden section.
                hiddenSection?.isHidden ?? false
            }
            if isHidden {
                result.insert(id)
            }
        }
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

    // MARK: Layout

    /// Assigns the app with the given entry identifier to a section.
    func assign(_ id: String, to section: MenuBarSection.Name) {
        guard id != ownEntryID else {
            return
        }
        var newAssignments = assignments
        newAssignments[id] = section
        assignments = newAssignments
        reconcile()
        refreshApps()
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

        let assignments = assignments
        let journal = journal
        let ownEntryID = ownEntryID

        var ids = Set(assignments.keys).union(journal)
        for pid in MenuBarAgentReader.owningProcessIdentifiers() {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                continue
            }
            let bundleIdentifier = app.bundleIdentifier
            let executablePath = app.executableURL?.path
            if let entry = entries.first(where: { $0.owns(bundleIdentifier: bundleIdentifier, executablePath: executablePath) }) {
                ids.insert(entry.id)
            }
        }

        apps = entries
            .filter { ids.contains($0.id) && $0.id != ownEntryID }
            .map { entry in
                let (name, icon) = Self.nameAndIcon(for: entry)
                return ManagedApp(
                    id: entry.id,
                    name: name,
                    icon: icon,
                    section: assignments[entry.id] ?? .visible,
                    isTurnedOffByUser: !entry.isAllowed && !journal.contains(entry.id)
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func nameAndIcon(for entry: MenuBarAllowList.Entry) -> (String, NSImage?) {
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
