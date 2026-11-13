import MacSanityCore
import SwiftUI
import UniformTypeIdentifiers

struct UninstallView: View {
    @Bindable var model: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove an app together with everything it keeps on your Mac — settings, caches, containers, login items. Or search for leftovers of an app you removed long ago.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                dropZone
                VStack(alignment: .leading, spacing: 8) {
                    Text("Search leftovers by name or bundle ID").font(.headline)
                    HStack {
                        TextField("e.g. spotify or com.spotify.client", text: $model.uninstallSearch)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.searchLeftovers() }
                        Button("Search") { model.searchLeftovers() }
                            .disabled(model.uninstallSearch.trimmingCharacters(in: .whitespaces).count < 3)
                    }
                }
            }
            Divider()
            results
        }
        .padding(24)
        .navigationTitle("Uninstall an App")
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "app.badge.checkmark").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Drop an app here").font(.headline)
            Button("Choose App…") { model.chooseAppToUninstall() }
        }
        .frame(width: 220, height: 130)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.tertiary))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            model.prepareUninstall(path: url.path)
            return true
        }
    }

    @ViewBuilder private var results: some View {
        if model.uninstallBusy {
            ProgressView("Looking for related files…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.uninstallItems.isEmpty {
            Text(model.uninstallApp == nil && model.uninstallSearch.isEmpty ? "Choose an app or search to see what it keeps on disk."
                 : "Nothing found.")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let app = model.uninstallApp {
                        Image(nsImage: model.icon(for: app.path)).resizable().frame(width: 32, height: 32)
                        Text(app.name).font(.title3.weight(.semibold))
                    } else {
                        Text("Found for “\(model.uninstallSearch)”").font(.title3.weight(.semibold))
                    }
                    Spacer()
                    Text(Bytes.format(selectedItems.reduce(0) { $0 + $1.size })).monospacedDigit()
                    Button(model.uninstallApp == nil ? "Move to Trash" : "Uninstall") { Task { await model.uninstall() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedItems.isEmpty)
                }
                List(model.uninstallItems, id: \.path) { item in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { model.uninstallSelection.contains(item.path) },
                            set: { on in
                                if on { model.uninstallSelection.insert(item.path) } else { model.uninstallSelection.remove(item.path) }
                            }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Text(item.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Bytes.format(item.size)).monospacedDigit().foregroundStyle(.secondary)
                        Button { model.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var selectedItems: [FindingItem] { model.uninstallSelectedItems }
}
