import SwiftUI

/// The standard Settings window (⌘,). Surfaces the scroll permissions, the
/// general toggles, and — importantly — the "Show Menu Bar Icon" switch, which
/// has a safe recovery path (reopen the app) so hiding it never locks anyone out.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Scroll Permissions") {
                permissionRow("Accessibility",
                              granted: model.permissions.accessibilityGranted,
                              pane: .accessibility)
                permissionRow("Input Monitoring",
                              granted: model.permissions.inputMonitoringGranted,
                              pane: .inputMonitoring)
                Text("Both are required to reverse scrolling. Keep Awake needs neither.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Start at Login", isOn: Binding(
                    get: { model.startAtLogin },
                    set: { model.setStartAtLogin($0) }))
                Toggle("Show Menu Bar Icon", isOn: Binding(
                    get: { model.showIcon },
                    set: { model.setHideIcon(!$0) }))
                Text("If you hide the icon, reopen MacSanity to bring it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }

    @ViewBuilder
    private func permissionRow(_ name: String, granted: Bool, pane: PermissionsManager.Pane) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(name)
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.secondary)
            } else {
                Button("Open System Settings") { model.permissions.openSettings(pane) }
            }
        }
    }
}
