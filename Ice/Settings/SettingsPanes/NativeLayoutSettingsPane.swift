//
//  NativeLayoutSettingsPane.swift
//  Ice
//

import SwiftUI

/// The menu bar layout pane on macOS 27, where apps are assigned to sections
/// instead of individual items being moved.
struct NativeLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var manager: NativeHidingManager

    @State private var targetedSection: MenuBarSection.Name?
    @State private var targetedApp: String?

    private var sections: [MenuBarSection.Name] {
        MenuBarSection.Name.allCases.filter { name in
            appState.menuBarManager.section(withName: name)?.isEnabled ?? false
        }
    }

    var body: some View {
        IceForm(spacing: 20) {
            header
            if NativeHidingManager.LayoutProfile.hasBuiltInDisplay {
                profilePicker
            }
            if let error = manager.lastError {
                errorBox(error)
            }
            ForEach(sections, id: \.self) { section in
                sectionBox(for: section)
            }
            footnote
        }
        .onAppear {
            manager.refreshApps()
        }
    }

    @ViewBuilder
    private var header: some View {
        IceSection {
            VStack(spacing: 3) {
                Text("Drag apps into the section where their menu bar items belong.")
                    .font(.title3.bold())
                Text("Visible apps are listed in menu bar order; to reorder them, ⌘ Command-drag them in the menu bar. Drag within a hidden section to set the order the Ice Bar uses.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("On macOS 27, Ice hides items app by app. System items such as the clock, Wi-Fi, Siri and Weather are managed in System Settings > Menu Bar.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(15)
        }
    }

    @ViewBuilder
    private var profilePicker: some View {
        VStack(spacing: 6) {
            Picker("Layout", selection: $manager.editingProfile) {
                ForEach(NativeHidingManager.LayoutProfile.allCases) { profile in
                    Text(LocalizedStringKey(profile.displayString)).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Text(profileCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var profileCaption: LocalizedStringKey {
        let inUse = manager.editingProfile == manager.activeProfile ? "In use now." : "Not in use right now."
        return switch manager.editingProfile {
        case .builtInDisplayOnly:
            LocalizedStringKey("Used when the laptop screen is the only display. \(inUse)")
        case .withExternalDisplay:
            LocalizedStringKey("Used when an external display is connected. \(inUse)")
        }
    }

    @ViewBuilder
    private func errorBox(_ error: String) -> some View {
        CalloutBox(LocalizedStringKey(error)) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private func sectionBox(for section: MenuBarSection.Name) -> some View {
        let apps = manager.apps.filter { $0.section == section }
        VStack(alignment: .leading) {
            HStack {
                Text(section.localized)
                    .font(.headline)
                Spacer()
                if section == .visible {
                    moveFoldedAppsButton
                }
            }
            .padding(.horizontal, 8)

            IceSection {
                if apps.isEmpty {
                    Text("Drop apps here")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                } else {
                    ForEach(apps) { app in
                        appRow(app)
                    }
                }
            }
            .overlay {
                if targetedSection == section {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                for id in ids {
                    manager.move(id, before: nil, in: section)
                }
                return !ids.isEmpty
            } isTargeted: { isTargeted in
                if isTargeted {
                    targetedSection = section
                } else if targetedSection == section {
                    targetedSection = nil
                }
            }
        }
    }

    /// Visible apps folded behind the overflow button. Only meaningful for
    /// the layout in use, since the menu bar reflects that one.
    private var foldedAppCount: Int {
        guard manager.editingProfile == manager.activeProfile else {
            return 0
        }
        return manager.apps.filter { $0.section == .visible && $0.isFolded }.count
    }

    @ViewBuilder
    private var moveFoldedAppsButton: some View {
        let count = foldedAppCount
        if count > 0 {
            Button(count == 1 ? "Move 1 Folded App to Hidden" : "Move \(count) Folded Apps to Hidden") {
                manager.moveFoldedAppsToHidden()
            }
            .help("Apps that don't fit in the menu bar are folded behind macOS's « button. Hidden apps appear in the Ice Bar instead.")
        }
    }

    @ViewBuilder
    private func appRow(_ app: NativeHidingManager.ManagedApp) -> some View {
        HStack {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(app.name)
            if app.isFolded, app.section == .visible, manager.editingProfile == manager.activeProfile {
                Text("Behind «")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if app.isTurnedOffByUser {
                Text("Off in System Settings")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Section", selection: Binding(
                get: { app.section },
                set: { manager.assign(app.id, to: $0) }
            )) {
                ForEach(sections, id: \.self) { section in
                    Text(section.localized).tag(section)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            // Shows where a dropped app will be inserted.
            if targetedApp == app.id {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .offset(y: -4)
            }
        }
        .dropDestination(for: String.self) { ids, _ in
            for id in ids {
                // The visible section follows the menu bar's order, so a drop
                // there only moves the app into the section.
                manager.move(id, before: app.section == .visible ? nil : app.id, in: app.section)
            }
            return !ids.isEmpty
        } isTargeted: { isTargeted in
            if isTargeted, app.section != .visible {
                targetedApp = app.id
            } else if targetedApp == app.id {
                targetedApp = nil
            }
        }
        .draggable(app.id) {
            Label {
                Text(app.name)
            } icon: {
                if let icon = app.icon {
                    Image(nsImage: icon)
                }
            }
        }
    }

    @ViewBuilder
    private var footnote: some View {
        Text("Ice hides an app by turning off its switch in System Settings > Menu Bar, and turns it back on when Ice quits. Before uninstalling Ice, choose \"Show All Apps and Quit\" from Ice's menu. If icons ever go missing, turn them back on in System Settings > Menu Bar.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }
}
