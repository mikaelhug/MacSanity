import MacSanityCore
import SwiftUI

/// The landing page: how much can go, one button to review it, and where it is.
struct OverviewView: View {
    let model: CleanerModel

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                if model.phase == .scanning {
                    ScanningView(model: model).padding(.top, 60)
                } else if model.result == nil {
                    ScanPlaceholder(model: model).frame(height: 360)
                } else {
                    hero
                    DiskBar(model: model)
                    if !model.fullDiskAccess { FullDiskAccessNotice(model: model) }
                    CategoryList(model: model)
                }
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Text(Bytes.text(model.selectedTotal))
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("ready to clean").font(.title3).foregroundStyle(.secondary)
            Button {
                model.reviewAndClean()
            } label: {
                Text("Review & Clean All").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selectedFindings.isEmpty || model.phase != .ready)
            .padding(.top, 6)
        }
    }
}

/// A large, calm progress display (no file paths).
struct ScanningView: View {
    let model: CleanerModel

    var body: some View {
        VStack(spacing: 14) {
            Text("\(Int(model.scanFraction * 100))%")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            ProgressView(value: model.scanFraction)
                .frame(maxWidth: 320)
            Text(model.status).foregroundStyle(.secondary)
            Button("Stop") { model.cancelScan() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DiskBar: View {
    let model: CleanerModel

    var body: some View {
        let volume = model.result?.volume
        let total = Double(max(volume?.total ?? 1, 1))
        let free = Double(volume?.availableForImportantUsage ?? 0)
        let used = max(0, total - free)
        let reclaim = min(Double(model.selectedTotal), used)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 2) {
                    Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(0, w * (used - reclaim) / total))
                    Capsule().fill(Color.green.opacity(0.75)).frame(width: max(0, w * reclaim / total))
                    Capsule().fill(.quaternary)
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(Bytes.text(Int64(used))) used")
                Spacer()
                Text("\(Bytes.text(Int64(free))) free")
            }
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// One quiet line; the steps live in a sheet.
struct FullDiskAccessNotice: View {
    @Bindable var model: CleanerModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock").foregroundStyle(.secondary)
            Text("Full Disk Access is off — some places aren't scanned.")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Grant Access…") { model.showFullDiskAccessHelp = true }
        }
        .font(.callout)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $model.showFullDiskAccessHelp) { FullDiskAccessSheet(model: model) }
    }
}

struct FullDiskAccessSheet: View {
    let model: CleanerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Full Disk Access").font(.title2.weight(.semibold))
            if model.canGrantFullDiskAccess {
                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Open Privacy Settings.")
                    step(2, "Click **+** and choose MacSanity, or drag it in from Finder.")
                    step(3, "Turn it on, then reopen MacSanity.")
                }
                HStack {
                    Button("Show in Finder") { model.revealAppForFullDiskAccess() }
                    Spacer()
                    Button("Close") { model.showFullDiskAccessHelp = false }
                    Button("Reopen") { model.relaunchForFullDiskAccess() }
                    Button("Open Settings") { model.openFullDiskAccessSettings() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text("This copy runs as a bare executable, which macOS can't grant access to. Open MacSanity.app instead.")
                    .foregroundStyle(.secondary)
                HStack { Spacer(); Button("Close") { model.showFullDiskAccessHelp = false } }
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)").font(.callout.weight(.semibold)).foregroundStyle(.secondary).frame(width: 16)
            Text(text)
        }
    }
}

/// Categories as a clean list: icon, name, size. Click to open.
struct CategoryList: View {
    let model: CleanerModel

    var body: some View {
        let categories = CleanerCategory.displayOrder.filter { model.count(in: $0) > 0 }
        VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                Button {
                    model.section = .category(category)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: category.symbol)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22)
                        Text(category.title)
                        Spacer()
                        let selected = model.selectedSize(in: category)
                        if selected > 0 {
                            Text("\(Bytes.text(selected)) selected")
                                .font(.callout).foregroundStyle(.green)
                        }
                        Text(model.summary(in: category))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 72, alignment: .trailing)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < categories.count - 1 { Divider().padding(.leading, 50) }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}
