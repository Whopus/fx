import SwiftUI

struct ItemTypeMenu: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Binding var selection: CaptureSpace
    let records: [CaptureRecord]

    var body: some View {
        let counts = Self.counts(in: records)
        let entries = [GlassMenuEntry.heading("Item Types", detail: "选择一种类型进行查看和管理")]
            + CaptureSpace.allCases.map { space in
                GlassMenuEntry(id: space.rawValue, title: space.displayName, icon: space.pickerIcon,
                    detail: space.summary, count: counts[space, default: 0], selected: selection == space) {
                        withAnimation(.easeOut(duration: 0.16)) { selection = space }
                    }
            }
        GlassMenu(entries: entries, width: 316, density: .catalog, accessibilityTitle: "Item Types") {
            HStack(spacing: 5) {
                Image(systemName: selection.pickerIcon)
                    .symbolRenderingMode(.monochrome).foregroundStyle(.secondary)
                Text(selection.displayName)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.black)
            .padding(.horizontal, 15)
            .frame(height: 36)
            .contentShape(Rectangle())
            .glassEffect(GlassMenuDensity.material(scheme: scheme, reduceTransparency: reduceTransparency), in: Capsule())
        }
        .fixedSize()
        .accessibilityValue(selection.displayName)
    }

    static func counts(in records: [CaptureRecord]) -> [CaptureSpace: Int] {
        records.reduce(into: [:]) { counts, record in
            guard !record.isTrashed else { return }
            counts[record.space ?? .context, default: 0] += 1
        }
    }
}

private extension CaptureSpace {
    var pickerIcon: String {
        switch self {
        case .system: "slider.horizontal.3"
        case .context: "square.on.square"
        case .query: "text.alignleft"
        case .tool: "wrench"
        case .skill: "sparkle"
        case .subagent: "person"
        case .session: "bubble.left"
        }
    }
}
