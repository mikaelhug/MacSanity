import MacSanityCore
import SwiftUI

struct CleanerRootView: View {
    @Bindable var model: CleanerModel

    var body: some View {
        NavigationSplitView {
            CleanerSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            CleanerDetail(model: model)
                .searchable(text: $model.query, placement: .toolbar, prompt: "Filter findings")
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.phase != .scanning {
                    Button {
                        model.startScan()
                    } label: {
                        Label(model.result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.phase == .cleaning)
                }
                if model.section != .overview && model.phase == .ready && !model.selectedFindings.isEmpty {
                    Button {
                        model.reviewAndClean()
                    } label: {
                        Text("Clean \(Bytes.text(model.selectedTotal))")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $model.showConfirm) { ConfirmSheet(model: model) }
        .sheet(isPresented: $model.showOutcome) { OutcomeSheet(model: model) }
    }
}

struct CleanerSidebar: View {
    @Bindable var model: CleanerModel

    var body: some View {
        List(selection: $model.section) {
            Section {
                Label("Overview", systemImage: "gauge.with.dots.needle.33percent").tag(CleanerSection.overview)
                Label("Disk Map", systemImage: "chart.bar.doc.horizontal").tag(CleanerSection.diskMap)
            }
            Section("Findings") {
                ForEach(CleanerCategory.displayOrder, id: \.self) { category in
                    SidebarCategoryRow(model: model, category: category)
                        .tag(CleanerSection.category(category))
                }
            }
            Section {
                Label("Uninstall an App…", systemImage: "trash").tag(CleanerSection.uninstall)
                Label("History", systemImage: "clock.arrow.circlepath").tag(CleanerSection.history)
            }
        }
        .listStyle(.sidebar)
    }
}

struct SidebarCategoryRow: View {
    let model: CleanerModel
    let category: CleanerCategory

    var body: some View {
        HStack {
            Label(category.title, systemImage: category.symbol)
            Spacer()
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        let state = model.progress[category]?.state
        if model.phase == .scanning && state == .scanning {
            ProgressView().controlSize(.mini)
        } else if model.result != nil {
            if model.count(in: category) > 0 {
                Text(model.summary(in: category)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct CleanerDetail: View {
    let model: CleanerModel

    var body: some View {
        switch model.section ?? .overview {
        case .overview: OverviewView(model: model)
        case .diskMap: DiskMapView(model: model)
        case .category(let c): FindingListView(model: model, category: c)
        case .uninstall: UninstallView(model: model)
        case .history: HistoryView(model: model)
        }
    }
}

/// Shown while a section has nothing to show yet.
struct ScanPlaceholder: View {
    let model: CleanerModel

    var body: some View {
        Group {
            if model.phase == .scanning {
                ScanningView(model: model)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "sparkles").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("See what you can clean").font(.title3)
                    Button("Scan") { model.startScan() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help(help)
    }

    private var label: String {
        switch safety { case .safe: "Safe"; case .review: "Review"; case .careful: "Careful" }
    }
    private var color: Color {
        switch safety { case .safe: .green; case .review: .orange; case .careful: .red }
    }
    private var help: String {
        switch safety {
        case .safe: "Rebuilt or re-downloaded automatically. Preselected."
        case .review: "Probably not needed, but take a look first."
        case .careful: "May contain something you want. Check before removing."
        }
    }
}
