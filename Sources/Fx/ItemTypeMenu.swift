import SwiftUI

/// The gallery's item-type selector.
///
/// The options are drawn with the app's liquid-glass surface instead of the
/// system `NSMenu`, whose material cannot carry the same clear, refractive
/// look. The rows stay compact and single-line so the control still reads like
/// a native pop-up menu.
struct ItemTypeMenu: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Binding var selection: CaptureSpace
    let records: [CaptureRecord]

    var body: some View {
        let entries = Self.options(selection: selection, records: records).map { option in
            GlassMenuEntry(id: option.space.rawValue, title: option.title, icon: option.icon,
                           count: option.count, selected: option.selected) {
                withAnimation(.easeOut(duration: 0.16)) { self.selection = option.space }
            }
        }
        GlassMenu(entries: entries, width: 224, density: .compact, accessibilityTitle: "Item Types") {
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

    /// A testable row description so the menu can be verified without opening it.
    struct Option: Equatable {
        let space: CaptureSpace
        let title: String
        let icon: String
        let count: Int
        let selected: Bool
    }

    static func options(selection: CaptureSpace, records: [CaptureRecord]) -> [Option] {
        let counts = counts(in: records)
        return CaptureSpace.allCases.map { space in
            Option(space: space, title: space.displayName, icon: space.pickerIcon,
                   count: counts[space, default: 0], selected: selection == space)
        }
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
