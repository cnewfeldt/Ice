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
                Text("Drag within a section to set the order the Ice Bar uses. To reorder items in the menu bar itself, ⌘ Command-drag them there.")
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
            Text(section.localized)
                .font(.headline)
                .padding(.leading, 8)

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

    @ViewBuilder
    private func appRow(_ app: NativeHidingManager.ManagedApp) -> some View {
        HStack {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(app.name)
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
                manager.move(id, before: app.id, in: app.section)
            }
            return !ids.isEmpty
        } isTargeted: { isTargeted in
            if isTargeted {
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
