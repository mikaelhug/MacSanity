import MacSanityCore
import SwiftUI

struct ConfirmSheet: View {
    let model: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text("You can put items back from the Trash or from History. Space is freed when the Trash is emptied.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.toCleanCategories, id: \.self) { c in
                    HStack {
                        Label(c.title, systemImage: c.symbol)
                        Spacer()
                        Text(Bytes.format(model.selectedSize(in: c))).monospacedDigit()
                    }
                }
            }
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

            let careful = model.toClean.filter { $0.safety == .careful }
            if !careful.isEmpty {
                warning("exclamationmark.triangle.fill", .red,
                        "\(careful.count) item(s) marked Careful are selected: " + careful.prefix(3).map(\.title).joined(separator: ", "))
            }
            let apps = model.appsToQuit
            if !apps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    warning("app.badge", .orange, "These apps are open and need to quit first:")
                    ForEach(apps, id: \.bundleID) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Button("Quit") { Task { await model.quit([app.bundleID]) } }
                        }
                        .padding(.leading, 24)
                    }
                    Button("Quit All") { Task { await model.quit(apps.map(\.bundleID)) } }.padding(.leading, 24)
                }
            }
            if !model.busyTools.isEmpty {
                warning("hammer.fill", .orange, "Running now: \(model.busyTools.joined(separator: ", ")). Let builds finish before cleaning their folders.")
            }
            if !model.commandsToRun.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("These cleanup commands will run:").font(.callout)
                    ForEach(model.commandsToRun, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            if model.needsAdmin {
                warning("lock.fill", .secondary, "Some items are system-wide; macOS will ask for your admin password once.")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.showConfirm = false }.keyboardShortcut(.cancelAction)
                Button("Move to Trash") { Task { await model.clean() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var title: String {
        let n = model.toClean.count
        let what = model.toCleanTotal > 0 ? Bytes.format(model.toCleanTotal) : (n == 1 ? "1 item" : "\(n) items")
        return "Move \(what) to the Trash?"
    }

    private func warning(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
}

struct OutcomeSheet: View {
    let model: CleanerModel

    var body: some View {
        let outcome = model.lastOutcome
        let inTrash = outcome?.entries.filter { $0.state == .inTrash } ?? []
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(Remover.isDryRun ? "Dry run — nothing was moved" : "Moved \(Bytes.format(outcome?.movedBytes ?? 0)) to the Trash")
                    .font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if let freed = model.lastSessionFreed {
                Text("Freed \(Bytes.format(freed)) by emptying those items from the Trash.").foregroundStyle(.secondary)
            } else if !inTrash.isEmpty {
                Text("The space is freed when these items leave the Trash. You can empty just them now — the rest of your Trash isn't touched.")
                    .foregroundStyle(.secondary)
            }
            if let failures = outcome?.failures, !failures.isEmpty {
                list("Couldn't clean", failures, .red)
            }
            if let skipped = outcome?.skipped, !skipped.isEmpty {
                list("Skipped", skipped, .orange)
            }
            HStack {
                Button("Open History") { model.showOutcome = false; model.refreshHistory(); model.section = .history }
                Spacer()
                if model.lastSessionFreed == nil && !inTrash.isEmpty {
                    Button("Empty These Items from Trash") { Task { await model.emptyLastSession() } }
                }
                Button("Done") { model.showOutcome = false }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func list(_ title: String, _ lines: [String], _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(color)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { Text($0).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .frame(maxHeight: 120)
        }
    }
}
