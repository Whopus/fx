import AppKit
import SwiftUI

struct SessionArtifactEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct SessionArtifactVisibleRow: Identifiable, Hashable {
    let entry: SessionArtifactEntry
    let depth: Int

    var id: String { entry.id }
}

private struct ContextThinScrollMetrics: Equatable {
    let scrollID: UUID
    let viewportHeight: CGFloat?
    let contentHeight: CGFloat?
    let contentMinY: CGFloat?
}

private struct ContextThinScrollMetricsKey: PreferenceKey {
    static let defaultValue: [ContextThinScrollMetrics] = []

    static func reduce(
        value: inout [ContextThinScrollMetrics],
        nextValue: () -> [ContextThinScrollMetrics]
    ) {
        value.append(contentsOf: nextValue())
    }
}

/// A compact, always-readable scroll position marker for narrow sidebar lists.
/// The marker is deliberately drawn only when the list actually overflows.
struct ContextThinVerticalScrollView<Content: View>: View {
    private let content: Content
    @State private var scrollID = UUID()
    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var contentMinY: CGFloat = 0

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var hasOverflow: Bool {
        contentHeight > viewportHeight + 1
    }

    private var thumbHeight: CGFloat {
        guard contentHeight > 0 else { return 0 }
        return min(28, max(12, viewportHeight * viewportHeight / contentHeight))
    }

    private var thumbOffset: CGFloat {
        let scrollableHeight = max(contentHeight - viewportHeight, 1)
        let availableTrackHeight = max(viewportHeight - thumbHeight, 0)
        let progress = min(max(-contentMinY / scrollableHeight, 0), 1)
        return progress * availableTrackHeight
    }

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ContextThinScrollMetricsKey.self,
                            value: [
                                ContextThinScrollMetrics(
                                    scrollID: scrollID,
                                    viewportHeight: nil,
                                    contentHeight: proxy.size.height,
                                    contentMinY: proxy.frame(in: .named(scrollID)).minY
                                )
                            ]
                        )
                    }
                )
        }
        .scrollIndicators(.hidden)
        .coordinateSpace(name: scrollID)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ContextThinScrollMetricsKey.self,
                    value: [
                        ContextThinScrollMetrics(
                            scrollID: scrollID,
                            viewportHeight: proxy.size.height,
                            contentHeight: nil,
                            contentMinY: nil
                        )
                    ]
                )
            }
        )
        .onPreferenceChange(ContextThinScrollMetricsKey.self) { metrics in
            guard let content = metrics.last(where: {
                $0.scrollID == scrollID && $0.contentHeight != nil
            }), let viewport = metrics.last(where: {
                $0.scrollID == scrollID && $0.viewportHeight != nil
            }) else {
                return
            }

            if let height = content.contentHeight,
               abs(contentHeight - height) > 0.5 {
                contentHeight = height
            }
            if let minY = content.contentMinY,
               abs(contentMinY - minY) > 0.5 {
                contentMinY = minY
            }
            if let height = viewport.viewportHeight,
               abs(viewportHeight - height) > 0.5 {
                viewportHeight = height
            }
        }
        .overlay(alignment: .topTrailing) {
            if hasOverflow {
                Capsule()
                    .fill(.black.opacity(0.82))
                    .frame(width: 2, height: thumbHeight)
                    .padding(.trailing, 1)
                    .offset(y: thumbOffset)
                    .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
final class SessionArtifactTreeModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var excludedTopLevelPaths: Set<String> = []
    @Published private(set) var excludesManagedItemDirectories = false
    @Published private(set) var childrenByDirectory: [URL: [SessionArtifactEntry]] = [:]
    @Published private(set) var loadingDirectories: Set<URL> = []
    @Published var errorMessage: String?

    func configure(
        rootURL: URL?,
        excludedTopLevelPaths: Set<String>,
        excludesManagedItemDirectories: Bool
    ) async {
        let normalized = rootURL?.standardizedFileURL
        let normalizedExclusions = Set(excludedTopLevelPaths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        guard self.rootURL != normalized
                || self.excludedTopLevelPaths != normalizedExclusions
                || self.excludesManagedItemDirectories != excludesManagedItemDirectories else {
            if let normalized, childrenByDirectory[normalized] == nil {
                await loadDirectory(normalized)
            }
            return
        }

        let rootChanged = self.rootURL != normalized
        self.rootURL = normalized
        self.excludedTopLevelPaths = normalizedExclusions
        self.excludesManagedItemDirectories = excludesManagedItemDirectories
        if rootChanged {
            childrenByDirectory.removeAll(keepingCapacity: true)
            loadingDirectories.removeAll(keepingCapacity: true)
        }
        errorMessage = nil
        if let normalized {
            await loadDirectory(normalized, force: true)
        }
    }

    func loadDirectory(_ directoryURL: URL, force: Bool = false) async {
        let directoryURL = directoryURL.standardizedFileURL
        guard force || childrenByDirectory[directoryURL] == nil else { return }
        guard !loadingDirectories.contains(directoryURL) else { return }
        loadingDirectories.insert(directoryURL)
        defer { loadingDirectories.remove(directoryURL) }

        do {
            let excludedPaths = directoryURL == rootURL ? excludedTopLevelPaths : []
            let excludesManagedDirectories = directoryURL == rootURL && excludesManagedItemDirectories
            let entries = try await Task.detached(priority: .utility) {
                try Self.scanDirectory(
                    directoryURL,
                    excluding: excludedPaths,
                    excludingManagedItemDirectories: excludesManagedDirectories
                )
            }.value
            guard directoryURL == rootURL || childrenByDirectory.keys.contains(where: {
                directoryURL.path.hasPrefix($0.path + "/")
            }) else { return }
            childrenByDirectory[directoryURL] = entries
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLoadedDirectories() async {
        guard let rootURL else { return }
        let loadedDirectories = Set(childrenByDirectory.keys).union([rootURL])
        let excludedTopLevelPaths = self.excludedTopLevelPaths
        let excludesManagedItemDirectories = self.excludesManagedItemDirectories
        let refreshed = await Task.detached(priority: .utility) {
            var result: [URL: [SessionArtifactEntry]] = [:]
            for directoryURL in loadedDirectories {
                if let entries = try? Self.scanDirectory(
                    directoryURL,
                    excluding: directoryURL == rootURL ? excludedTopLevelPaths : [],
                    excludingManagedItemDirectories: directoryURL == rootURL && excludesManagedItemDirectories
                ) {
                    result[directoryURL] = entries
                }
            }
            return result
        }.value
        guard self.rootURL == rootURL else { return }
        for (directoryURL, entries) in refreshed {
            childrenByDirectory[directoryURL] = entries
        }
    }

    func visibleRows(expandedPaths: Set<String>) -> [SessionArtifactVisibleRow] {
        guard let rootURL else { return [] }
        var rows: [SessionArtifactVisibleRow] = []

        func appendChildren(of directoryURL: URL, depth: Int) {
            for entry in childrenByDirectory[directoryURL] ?? [] {
                rows.append(SessionArtifactVisibleRow(entry: entry, depth: depth))
                if entry.isDirectory, expandedPaths.contains(entry.id) {
                    appendChildren(of: entry.url, depth: depth + 1)
                }
            }
        }

        appendChildren(of: rootURL, depth: 0)
        return rows
    }

    func trash(_ entry: SessionArtifactEntry) async {
        do {
            try await Task.detached(priority: .utility) {
                var resultingURL: NSURL?
                try FileManager.default.trashItem(at: entry.url, resultingItemURL: &resultingURL)
            }.value
            childrenByDirectory[entry.url] = nil
            await refreshLoadedDirectories()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static func scanDirectory(
        _ directoryURL: URL,
        excluding excludedPaths: Set<String> = [],
        excludingManagedItemDirectories: Bool = false
    ) throws -> [SessionArtifactEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return try urls.compactMap { url in
            let normalizedURL = url.standardizedFileURL
            guard !excludedPaths.contains(normalizedURL.path) else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            let isDirectory = values.isDirectory == true && values.isSymbolicLink != true
            if excludingManagedItemDirectories,
               isDirectory,
               FileManager.default.fileExists(
                   atPath: normalizedURL.appendingPathComponent("metadata.json").path
               ) {
                return nil
            }
            return SessionArtifactEntry(
                url: normalizedURL,
                isDirectory: isDirectory
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct ContextSessionArtifactsView: View {
    let rootURL: URL?
    let excludedTopLevelPaths: Set<String>
    let excludesManagedItemDirectories: Bool
    let refreshRevision: Int

    @StateObject private var model = SessionArtifactTreeModel()
    @State private var expandedPaths: Set<String> = []
    @State private var selectedPath: String?

    private var visibleRows: [SessionArtifactVisibleRow] {
        model.visibleRows(expandedPaths: expandedPaths)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(.black.opacity(0.06))
                .frame(height: 1)

            HStack(spacing: 7) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 11, weight: .medium))
                Text("Artifacts")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 6)
                Button {
                    Task { await model.refreshLoadedDirectories() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary.opacity(0.72))
                .help("刷新文件树")
            }
            .foregroundStyle(.secondary.opacity(0.78))
            .padding(.top, 12)

            if let rootURL = model.rootURL {
                ContextThinVerticalScrollView {
                    if visibleRows.isEmpty,
                       !model.loadingDirectories.contains(rootURL) {
                        Text("No artifacts yet")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary.opacity(0.48))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visibleRows) { row in
                                artifactRow(row)
                            }
                        }
                    }
                }
            } else {
                Text("No working directory")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.48))
                    .padding(.top, 9)
            }
        }
        .task(id: configurationIdentity) {
            expandedPaths.removeAll(keepingCapacity: true)
            selectedPath = nil
            await model.configure(
                rootURL: rootURL,
                excludedTopLevelPaths: excludedTopLevelPaths,
                excludesManagedItemDirectories: excludesManagedItemDirectories
            )
        }
        .onChange(of: refreshRevision) { _, _ in
            Task { await model.refreshLoadedDirectories() }
        }
        .alert("Artifacts", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "文件操作失败。")
        }
    }

    private var configurationIdentity: String {
        ([
            rootURL?.standardizedFileURL.path ?? "",
            excludesManagedItemDirectories ? "managed" : "unmanaged"
        ] + excludedTopLevelPaths.sorted())
            .joined(separator: "\u{0}")
    }

    private func artifactRow(_ row: SessionArtifactVisibleRow) -> some View {
        let entry = row.entry
        let isExpanded = expandedPaths.contains(entry.id)
        let isSelected = selectedPath == entry.id

        return HStack(spacing: 5) {
            if entry.isDirectory {
                Button {
                    toggleDirectory(entry)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 12, height: 18)
            }

            Image(systemName: artifactIcon(for: entry))
                .font(.system(size: 11, weight: .regular))
                .frame(width: 14)
                .foregroundStyle(entry.isDirectory ? Color.black.opacity(0.72) : Color.secondary.opacity(0.68))

            Text(entry.name)
                .font(.system(size: 11.5))
                .foregroundStyle(.black.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if model.loadingDirectories.contains(entry.url) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 13)
        .padding(.horizontal, 4)
        .frame(height: 25)
        .background(isSelected ? Color.black.opacity(0.055) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectedPath = entry.id
            if entry.isDirectory {
                toggleDirectory(entry)
            } else {
                NSWorkspace.shared.open(entry.url)
            }
        }
        .onTapGesture {
            selectedPath = entry.id
        }
        .contextMenu {
            Button(entry.isDirectory ? "打开" : "打开文件") {
                NSWorkspace.shared.open(entry.url)
            }
            Divider()
            Button("复制") { writeToPasteboard(entry.url, operation: "copy") }
            Button("剪切") { writeToPasteboard(entry.url, operation: "cut") }
            Divider()
            Button("删除", role: .destructive) {
                expandedPaths.remove(entry.id)
                if selectedPath == entry.id { selectedPath = nil }
                Task { await model.trash(entry) }
            }
            Divider()
            Button("打开所在文件夹") {
                NSWorkspace.shared.activateFileViewerSelecting([entry.url])
            }
        }
        .help(entry.url.path)
    }

    private func toggleDirectory(_ entry: SessionArtifactEntry) {
        if expandedPaths.remove(entry.id) == nil {
            expandedPaths.insert(entry.id)
            Task { await model.loadDirectory(entry.url) }
        }
    }

    private func writeToPasteboard(_ url: URL, operation: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(
            operation,
            forType: NSPasteboard.PasteboardType("org.curatez.file-operation")
        )
    }

    private func artifactIcon(for entry: SessionArtifactEntry) -> String {
        if entry.isDirectory { return "folder" }
        switch entry.url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            return "photo"
        case "mov", "mp4", "m4v", "webm":
            return "film"
        case "mp3", "m4a", "wav", "aac":
            return "waveform"
        case "zip", "tar", "gz", "7z":
            return "archivebox"
        case "swift", "rs", "ts", "js", "py", "sh", "json", "yaml", "yml":
            return "chevron.left.forwardslash.chevron.right"
        default:
            return "doc"
        }
    }
}
