import MacSanityCore
import SwiftUI

struct DiskMapView: View {
    let model: CleanerModel

    var body: some View {
        Group {
            if let node = model.diskMapNode {
                List {
                    breadcrumb(node)
                    ForEach(node.children) { child in
                        DiskMapRow(model: model, node: child, parentSize: node.size)
                    }
                    if node.otherSize > 0 {
                        HStack {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).frame(width: 20)
                            Text("Smaller items").foregroundStyle(.secondary)
                            Spacer()
                            Text(Bytes.format(node.otherSize)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ScanPlaceholder(model: model)
            }
        }
        .navigationTitle("Disk Map")
    }

    private func breadcrumb(_ node: DiskNode) -> some View {
        let parts = node.path == "/" ? [] : node.path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Macintosh HD") { model.diskMapPath = "/" }.buttonStyle(.link)
                ForEach(parts.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Button(parts[i]) { model.diskMapPath = "/" + parts[0...i].joined(separator: "/") }
                        .buttonStyle(.link)
                }
                Spacer()
                Text(Bytes.format(node.size)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

struct DiskMapRow: View {
    let model: CleanerModel
    let node: DiskNode
    let parentSize: Int64

    var body: some View {
        let reclaim = model.reclaimable(under: node.path)
        HStack(spacing: 10) {
            Image(systemName: node.isDirectory ? (node.children.isEmpty ? "shippingbox" : "folder") : "doc")
                .foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if node.name.hasPrefix(".") {
                        Text("hidden").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                    if node.unreadable > 0 {
                        Image(systemName: "lock").font(.caption2).foregroundStyle(.orange)
                            .help("Some folders inside couldn't be read. Grant Full Disk Access to see them.")
                    }
                }
                GeometryReader { geo in
                    let fraction = parentSize > 0 ? CGFloat(node.size) / CGFloat(parentSize) : 0
                    let reclaimFraction = parentSize > 0 ? CGFloat(reclaim.size) / CGFloat(parentSize) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: geo.size.width * fraction)
                        Capsule().fill(.green.opacity(0.8)).frame(width: geo.size.width * min(reclaimFraction, fraction))
                    }
                }
                .frame(height: 5)
            }
            if reclaim.size > 0 {
                Button {
                    if let first = reclaim.categories.first { model.section = .category(first) }
                } label: {
                    Text("\(Bytes.format(reclaim.size)) reclaimable")
                        .font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: Capsule()).foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Found in: " + reclaim.categories.map(\.title).joined(separator: ", "))
            }
            Text(Bytes.format(node.size)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Menu {
                Button("Reveal in Finder") { model.reveal(node.path) }
                if reclaim.size > 0 { Button("Select Findings Inside") { model.selectFindings(under: node.path) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if node.isDirectory && !node.children.isEmpty { model.diskMapPath = node.path }
        }
    }
}
