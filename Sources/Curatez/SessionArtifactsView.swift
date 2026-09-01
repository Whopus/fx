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

@MainActor
final class SessionArtifactTreeModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var childrenByDirectory: [URL: [SessionArtifactEntry]] = [:]
    @Published private(set) var loadingDirectories: Set<URL> = []
    @Published var errorMessage: String?

    func configure(rootURL: URL?) async {
        let normalized = rootURL?.standardizedFileURL
        guard self.rootURL != normalized else {
            if let normalized, childrenByDirectory[normalized] == nil {
                await loadDirectory(normalized)
            }
            return
        }

        self.rootURL = normalized
        childrenByDirectory.removeAll(keepingCapacity: true)
        loadingDirectories.removeAll(keepingCapacity: true)
        errorMessage = nil
        if let normalized {
            await loadDirectory(normalized)
        }
    }

    func loadDirectory(_ directoryURL: URL, force: Bool = false) async {
        let directoryURL = directoryURL.standardizedFileURL
        guard force || childrenByDirectory[directoryURL] == nil else { return }
        guard !loadingDirectories.contains(directoryURL) else { return }
        loadingDirectories.insert(directoryURL)
        defer { loadingDirectories.remove(directoryURL) }

        do {
            let entries = try await Task.detached(priority: .utility) {
                try Self.scanDirectory(directoryURL)
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
        let refreshed = await Task.detached(priority: .utility) {
            var result: [URL: [SessionArtifactEntry]] = [:]
            for directoryURL in loadedDirectories {
                if let entries = try? Self.scanDirectory(directoryURL) {
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

    nonisolated static func scanDirectory(_ directoryURL: URL) throws -> [SessionArtifactEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return try urls.map { url in
            let values = try url.resourceValues(forKeys: keys)
            return SessionArtifactEntry(
                url: url.standardizedFileURL,
                isDirectory: values.isDirectory == true && values.isSymbolicLink != true
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
                Text(rootURL.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.52))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rootURL.path)
                    .padding(.top, 2)
                    .padding(.bottom, 7)

                ScrollView {
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
                .scrollIndicators(.hidden)
            } else {
                Text("No working directory")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary.opacity(0.48))
                    .padding(.top, 9)
            }
        }
        .task(id: rootURL?.standardizedFileURL.path) {
            expandedPaths.removeAll(keepingCapacity: true)
            selectedPath = nil
            await model.configure(rootURL: rootURL)
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
