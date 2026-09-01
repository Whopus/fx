import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ContextEditorFocus: Hashable {
    case title(UUID)
    case body(UUID)
}

private enum ContextPrimaryAction: String, CaseIterable, Identifiable {
    case run = "Run"
    case save = "Save"

    var id: Self { self }

    var icon: String {
        switch self {
        case .run: "play.fill"
        case .save: "tray.and.arrow.down"
        }
    }
}

@MainActor
private final class ContextScrollAnimationDriver: NSObject {
    private var displayLink: CADisplayLink?
    private var update: ((CFTimeInterval) -> Bool)?

    func start(for view: NSView, update: @escaping (CFTimeInterval) -> Bool) {
        stop()
        self.update = update
        let displayLink = view.displayLink(target: self, selector: #selector(step(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        update = nil
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        if update?(CACurrentMediaTime()) == true {
            stop()
        }
    }
}

@MainActor
private final class ContextEditorScrollCache: NSObject {
    private final class WeakAnchor {
        weak var view: NSView?

        init(_ view: NSView) {
            self.view = view
        }
    }

    private weak var scrollView: NSScrollView?
    private var anchors: [UUID: WeakAnchor] = [:]
    private var scheduledSelectionRefresh = false
    private var lastReportedItemID: UUID?
    var onActiveItemChange: ((UUID) -> Void)?
    var resolvedScrollView: NSScrollView? { scrollView }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func install(scrollView: NSScrollView) {
        guard self.scrollView !== scrollView else {
            scheduleSelectionRefresh()
            return
        }

        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: self.scrollView?.contentView
        )
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scheduleSelectionRefresh()
    }

    func register(_ anchor: NSView, for itemID: UUID) {
        guard anchors[itemID]?.view !== anchor else { return }
        anchors[itemID] = WeakAnchor(anchor)
        scheduleSelectionRefresh()
    }

    func unregister(_ anchor: NSView, for itemID: UUID) {
        guard anchors[itemID]?.view === anchor else { return }
        anchors[itemID] = nil
        if lastReportedItemID == itemID {
            lastReportedItemID = nil
        }
    }

    func relativePosition(for itemID: UUID) -> CGFloat? {
        guard let scrollView,
              let anchor = anchors[itemID]?.view,
              anchor.window != nil else { return nil }
        return relativeTop(of: anchor, in: scrollView.contentView)
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        refreshActiveItem()
    }

    private func scheduleSelectionRefresh() {
        guard !scheduledSelectionRefresh else { return }
        scheduledSelectionRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduledSelectionRefresh = false
            self.refreshActiveItem()
        }
    }

    private func refreshActiveItem() {
        guard let scrollView else { return }
        let clipView = scrollView.contentView
        anchors = anchors.filter { $0.value.view != nil }
        let positions = anchors.compactMap { itemID, anchor -> (UUID, CGFloat)? in
            guard let view = anchor.view, view.window != nil else { return nil }
            return (itemID, relativeTop(of: view, in: clipView))
        }
        guard let activeItemID = Self.activeItemID(in: positions),
              activeItemID != lastReportedItemID else { return }
        lastReportedItemID = activeItemID
        onActiveItemChange?(activeItemID)
    }

    private func relativeTop(of anchor: NSView, in clipView: NSClipView) -> CGFloat {
        let rect = anchor.convert(anchor.bounds, to: clipView)
        if clipView.isFlipped {
            return rect.minY - clipView.bounds.minY
        }
        return clipView.bounds.maxY - rect.maxY
    }

    private static func activeItemID(in positions: [(UUID, CGFloat)]) -> UUID? {
        guard !positions.isEmpty else { return nil }
        let activationLine: CGFloat = 54
        if let passed = positions
            .filter({ $0.1 <= activationLine })
            .max(by: { $0.1 < $1.1 }) {
            return passed.0
        }
        return positions.min(by: {
            abs($0.1 - activationLine) < abs($1.1 - activationLine)
        })?.0
    }
}

@MainActor
private final class ContextMarkdownPreviewCache {
    struct Value {
        let source: String
        let normalized: String
        let collapsed: String
        let totalLines: Int
        let lineLimit: Int
    }

    private var values: [UUID: Value] = [:]

    func preview(
        for source: String,
        itemID: UUID,
        lineLimit: Int,
        isExpanded: Bool
    ) -> (markdown: String, totalLines: Int, canToggle: Bool, isExpanded: Bool) {
        let value: Value
        if let cached = values[itemID],
           cached.lineLimit == lineLimit,
           cached.source == source {
            value = cached
        } else {
            let normalized = source
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .newlines)
            let lines = normalized.isEmpty
                ? []
                : normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            value = Value(
                source: source,
                normalized: normalized,
                collapsed: lines.prefix(lineLimit).joined(separator: "\n"),
                totalLines: lines.count,
                lineLimit: lineLimit
            )
            values[itemID] = value
        }

        let canToggle = value.totalLines > lineLimit
        return (
            isExpanded || !canToggle ? value.normalized : value.collapsed,
            value.totalLines,
            canToggle,
            isExpanded
        )
    }

    func removeValue(for itemID: UUID) {
        values[itemID] = nil
    }
}

@MainActor
private final class ContextModelPickerClickMonitor {
    private var monitor: Any?

    func start(onMouseUp: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { event in
            onMouseUp()
            return event
        }
    }

    func stop() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }
}

struct ContextLiveActivity: Equatable {
    enum EntryKind: Equatable {
        case reasoning
        case response
        case toolCall
        case toolResult
    }

    struct Entry: Identifiable, Equatable {
        let id: String
        var kind: EntryKind
        var title: String
        var detail: String
        var toolName: String? = nil
        var payload: JSONValue? = nil
        var toolCallID: String? = nil
        var resultDetail: String? = nil
        var resultPayload: JSONValue? = nil
        var isResultRunning = false
        var isError = false
    }

    var entries: [Entry] = []
    var activeText = "Thinking…"

    mutating func apply(_ event: ContextRunEvent) {
        let data = event.data.objectValue ?? [:]

        if event.type.hasSuffix("message_update"),
           let update = data["assistantMessageEvent"]?.objectValue,
           let updateType = update["type"]?.stringValue {
            applyMessageUpdate(type: updateType, update: update)
            return
        }

        if event.type.hasSuffix("tool_execution_start") {
            let id = data["toolCallId"]?.stringValue ?? UUID().uuidString
            let name = data["toolName"]?.stringValue ?? "tool"
            upsert(
                Entry(
                    id: "tool-\(id)",
                    kind: .toolCall,
                    title: name,
                    detail: data["args"]?.displayText ?? "",
                    toolName: name,
                    payload: data["args"],
                    toolCallID: id
                )
            )
            activeText = event.type.hasPrefix("subagent/")
                ? "Subagent running \(name)…"
                : "Running \(name)…"
            return
        }

        if event.type.hasSuffix("tool_execution_update") {
            let id = data["toolCallId"]?.stringValue ?? UUID().uuidString
            let name = data["toolName"]?.stringValue ?? "tool"
            if let partialResult = data["partialResult"], !partialResult.displayText.isEmpty {
                mergeToolResult(
                    id: id,
                    name: name,
                    detail: partialResult.displayText,
                    payload: partialResult,
                    isRunning: true,
                    isError: false
                )
            }
            activeText = "Running \(name)…"
            return
        }

        if event.type.hasSuffix("tool_execution_end") {
            let id = data["toolCallId"]?.stringValue ?? UUID().uuidString
            let name = data["toolName"]?.stringValue ?? "tool"
            let isError = data["isError"]?.boolValue ?? false
            mergeToolResult(
                id: id,
                name: name,
                detail: data["result"]?.displayText ?? "Completed",
                payload: data["result"],
                isRunning: false,
                isError: isError
            )
            activeText = isError ? "Handling \(name) error…" : "Reading \(name) result…"
            return
        }

        switch event.type {
        case "agent_start", "turn_start", "fx/round_start":
            activeText = "Thinking…"
        case "turn_end", "fx/round_end", "agent_end":
            activeText = "Finishing response…"
        case "runtime/error":
            activeText = "Run failed"
        default:
            if event.type.hasPrefix("subagent/") {
                activeText = "Subagent thinking…"
            }
        }
    }

    private mutating func applyMessageUpdate(type: String, update: [String: JSONValue]) {
        switch type {
        case "thinking_start":
            entries.append(Entry(
                id: "reasoning-\(entries.count)",
                kind: .reasoning,
                title: "Thinking",
                detail: ""
            ))
            activeText = "Thinking…"
        case "thinking_delta":
            append(update["delta"]?.stringValue ?? "", to: .reasoning, title: "Thinking")
            activeText = "Thinking…"
        case "thinking_end":
            replaceLastDetail(update["content"]?.stringValue, kind: .reasoning)
            activeText = "Preparing next step…"
        case "text_start":
            entries.append(Entry(
                id: "response-\(entries.count)",
                kind: .response,
                title: "Response",
                detail: ""
            ))
            activeText = "Writing response…"
        case "text_delta":
            append(update["delta"]?.stringValue ?? "", to: .response, title: "Response")
            activeText = "Writing response…"
        case "text_end":
            replaceLastDetail(update["content"]?.stringValue, kind: .response)
            activeText = "Finishing response…"
        case "toolcall_start", "toolcall_delta":
            activeText = "Preparing tool call…"
        case "toolcall_end":
            activeText = "Starting tool…"
        default:
            break
        }
    }

    private mutating func append(_ delta: String, to kind: EntryKind, title: String) {
        guard !delta.isEmpty else { return }
        if let index = entries.lastIndex(where: { $0.kind == kind }) {
            entries[index].detail += delta
        } else {
            entries.append(Entry(
                id: "\(title.lowercased())-\(entries.count)",
                kind: kind,
                title: title,
                detail: delta
            ))
        }
    }

    private mutating func replaceLastDetail(_ detail: String?, kind: EntryKind) {
        guard let detail, !detail.isEmpty,
              let index = entries.lastIndex(where: { $0.kind == kind }) else { return }
        entries[index].detail = detail
    }

    private mutating func upsert(_ entry: Entry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private mutating func mergeToolResult(
        id: String,
        name: String,
        detail: String,
        payload: JSONValue?,
        isRunning: Bool,
        isError: Bool
    ) {
        if let index = entries.lastIndex(where: { $0.kind == .toolCall && $0.toolCallID == id }) {
            entries[index].resultDetail = detail
            entries[index].resultPayload = payload
            entries[index].isResultRunning = isRunning
            entries[index].isError = isError
            return
        }

        entries.append(Entry(
            id: "tool-\(id)",
            kind: .toolCall,
            title: name,
            detail: "",
            toolName: name,
            toolCallID: id,
            resultDetail: detail,
            resultPayload: payload,
            isResultRunning: isRunning,
            isError: isError
        ))
    }
}

@MainActor
private final class ContextLiveActivityStore: ObservableObject {
    @Published private(set) var activity = ContextLiveActivity()
    private var accumulatedActivity = ContextLiveActivity()
    private var scheduledFlush: Task<Void, Never>?

    func reset() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        accumulatedActivity = ContextLiveActivity()
        activity = accumulatedActivity
    }

    func apply(_ event: ContextRunEvent) {
        accumulatedActivity.apply(event)

        // Token deltas can arrive hundreds of times per second. Publishing each one
        // invalidates the Markdown and tool hierarchy, so coalesce them to a smooth
        // 8 fps while flushing structural/end events immediately.
        if Self.requiresImmediateFlush(event.type) {
            flush()
        } else if scheduledFlush == nil {
            scheduledFlush = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(125))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    private func flush() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard activity != accumulatedActivity else { return }
        activity = accumulatedActivity
    }

    private static func requiresImmediateFlush(_ type: String) -> Bool {
        type.hasSuffix("_start")
            || type.hasSuffix("_end")
            || type.hasSuffix("tool_execution_start")
            || type.hasSuffix("tool_execution_end")
            || type == "runtime/error"
    }
}

private struct ContextItemDropDelegate: DropDelegate {
    let destinationID: UUID
    @Binding var items: [ContextNotebookItem]
    @Binding var draggedItemID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedItemID,
              draggedItemID != destinationID,
              let sourceIndex = items.firstIndex(where: { $0.id == draggedItemID }),
              let destinationIndex = items.firstIndex(where: { $0.id == destinationID }) else { return }

        withAnimation(.easeOut(duration: 0.16)) {
            items.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}

struct CollectionEditorView: View {
    @ObservedObject var store: CaptureStore
    let initialSessionID: UUID?
    let onClose: () -> Void

    @State private var notebook = ContextNotebook.fresh(title: "Context")
    @State private var selectedItemID: UUID?
    @State private var navigationTargetID: UUID?
    @State private var navigationLockID: UUID?
    @State private var hoveredItemID: UUID?
    @State private var draggedItemID: UUID?
    @State private var hoveredInsertionIndex: Int?
    @State private var libraryInsertionIndex: Int?
    @State private var libraryReplacementItemID: UUID?
    @State private var libraryItemKind: ContextCellKind = .context
    @State private var isLoaded = false
    @State private var isRunning = false
    @State private var isLibraryPresented = false
    @State private var isCloseConfirmationPresented = false
    @State private var primaryAction: ContextPrimaryAction = .run
    @State private var activeSessionID: UUID?
    @State private var shouldKeepSessionOnClose = false
    @State private var didSaveSession = false
    @State private var saveFeedbackGeneration = 0
    @State private var errorMessage: String?
    @State private var documentScrollCache = ContextEditorScrollCache()
    @State private var scrollAnimationDriver = ContextScrollAnimationDriver()
    @State private var liveActivityStore = ContextLiveActivityStore()
    @State private var liveOutputID: UUID?
    @State private var fxModelSettings = FxModelSettings.empty
    @State private var isModelPickerPresented = false
    @State private var modelPickerLevelSpec: String?
    @State private var hoveredModelPickerRow: String?
    @State private var modelPickerInteractionEpoch = 0
    @State private var modelPickerClickMonitor = ContextModelPickerClickMonitor()
    @State private var expandedMarkdownItemIDs: Set<UUID> = []
    @State private var markdownPreviewCache = ContextMarkdownPreviewCache()
    @State private var availableRecordsSnapshot: [CaptureRecord] = []
    @State private var availableRecordsByID: [UUID: CaptureRecord] = [:]
    @State private var artifactRefreshRevision = 0
    @FocusState private var focusedEditorField: ContextEditorFocus?

    private var runtimeWorkingDirectoryURL: URL? {
        store.selectedCollection.map(store.workingDirectoryURL(for:))
    }

    private var availableRecords: [CaptureRecord] {
        availableRecordsSnapshot
    }

    private var libraryRecords: [CaptureRecord] {
        guard let space = libraryItemKind.captureSpace else { return [] }
        return availableRecords.filter { ($0.space ?? .context) == space }
    }

    private var managedLibraryItemPaths: Set<String> {
        Set(availableRecords.compactMap { record in
            store.containerURL(for: record)?.standardizedFileURL.path
        })
    }

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(260, max(230, geometry.size.width * 0.27))
            HStack(spacing: 0) {
                sidebar.frame(width: sidebarWidth)
                editorContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .ignoresSafeArea()
        .onAppear(perform: loadNotebook)
        .onReceive(store.$records) { records in
            let available = records.filter { !$0.isTrashed }
            availableRecordsSnapshot = available
            availableRecordsByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        }
        .onExitCommand {
            if isModelPickerPresented {
                dismissModelPicker()
            } else {
                requestCloseEditor()
            }
        }
        .onDisappear {
            scrollAnimationDriver.stop()
            modelPickerClickMonitor.stop()
            try? discardSessionDraftIfNeeded()
        }
        .sheet(isPresented: $isLibraryPresented, onDismiss: finishLibrarySelection) {
            ContextLibraryPicker(
                store: store,
                itemType: libraryItemKind.captureSpace ?? .context,
                records: libraryRecords,
                isReplacing: libraryReplacementItemID != nil,
                onSelect: addRecords
            )
        }
        .alert("Context Editor", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .confirmationDialog(
            "保存这个 Session？",
            isPresented: $isCloseConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("保存到 Session") { saveAndCloseEditor() }
            Button("不保存", role: .destructive) { discardAndCloseEditor() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存会在 Session 类型中创建一个新 Item；不保存会丢弃本次编辑内容。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: requestCloseEditor) {
                Text("Back")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary.opacity(0.72))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(y: -8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(notebook.items.enumerated()), id: \.element.id) { index, item in
                        insertionControl(at: index)
                        sidebarButton(item, index: index)
                    }

                    insertionControl(at: notebook.items.count)

                    addMenu
                        .padding(.top, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .padding(.top, 7)

            ContextSessionArtifactsView(
                rootURL: runtimeWorkingDirectoryURL,
                excludedTopLevelPaths: managedLibraryItemPaths,
                refreshRevision: artifactRefreshRevision
            )
            .frame(minHeight: 190, idealHeight: 280, maxHeight: 340)
            .padding(.top, 12)
        }
        .padding(.leading, 28)
        .padding(.trailing, 28)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white)
    }

    private func sidebarButton(_ item: ContextNotebookItem, index: Int) -> some View {
        let selected = item.id == selectedItemID
        let hovered = item.id == hoveredItemID
        return HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(sidebarTitle(for: item))
                    .font(.system(size: 14, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                if selected {
                    Rectangle().fill(Color.black).frame(width: 7, height: 7)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.black : Color.secondary.opacity(0.58))
            .contentShape(Rectangle())
            .onTapGesture {
                navigationLockID = item.id
                withAnimation(.contextNavigation) {
                    selectedItemID = item.id
                }
                navigationTargetID = item.id
            }

            HStack(spacing: 0) {
                Menu {
                    replaceMenuContent(itemID: item.id)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary.opacity(0.68))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.secondary.opacity(0.68))
                .fixedSize()
                .help("替换 item")

                Button {
                    deleteItem(item.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.68))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("删除 item")
            }
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredItemID = item.id
            } else if hoveredItemID == item.id {
                hoveredItemID = nil
            }
        }
        .onDrag {
            draggedItemID = item.id
            return NSItemProvider(object: item.id.uuidString as NSString)
        } preview: {
            Text(sidebarTitle(for: item))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.1), radius: 7, y: 2)
        }
        .onDrop(
            of: [UTType.text],
            delegate: ContextItemDropDelegate(
                destinationID: item.id,
                items: $notebook.items,
                draggedItemID: $draggedItemID
            )
        )
        .contextMenu {
            Button("上移") { moveItem(from: index, offset: -1) }.disabled(index == 0)
            Button("下移") { moveItem(from: index, offset: 1) }.disabled(index == notebook.items.count - 1)
            Divider()
            Button("删除", role: .destructive) { deleteItem(item.id) }
        }
    }

    private var addMenu: some View {
        Menu {
            addMenuContent(insertionIndex: nil)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 30, height: 30)
                .background(.black.opacity(0.045))
                .clipShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("添加 item")
    }

    private func insertionControl(at index: Int) -> some View {
        let visible = hoveredInsertionIndex == index
        return HStack(spacing: 6) {
            Rectangle()
                .fill(visible ? Color.black.opacity(0.28) : Color.clear)
                .frame(height: 1)

            Menu {
                addMenuContent(insertionIndex: index)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.78))
                    .frame(width: 18, height: 18)
                    .background(.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.black.opacity(0.22), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)

            Rectangle()
                .fill(visible ? Color.black.opacity(0.28) : Color.clear)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 18)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredInsertionIndex = index
            } else if hoveredInsertionIndex == index {
                hoveredInsertionIndex = nil
            }
        }
        .animation(.easeOut(duration: 0.12), value: visible)
    }

    @ViewBuilder
    private func addMenuContent(insertionIndex: Int?) -> some View {
        Button { addItem(.placeholder, at: insertionIndex) } label: {
            Label("空白占位", systemImage: "square.dashed")
        }
        Divider()
        ForEach(ContextCellKind.inputKinds) { kind in
            Button {
                if kind == .query {
                    addItem(.query, at: insertionIndex)
                } else {
                    libraryItemKind = kind
                    libraryInsertionIndex = insertionIndex
                    libraryReplacementItemID = nil
                    isLibraryPresented = true
                }
            } label: {
                Label(kind.menuLabel, systemImage: kind.icon)
            }
        }
    }

    @ViewBuilder
    private func replaceMenuContent(itemID: UUID) -> some View {
        Button {
            replaceItem(itemID, with: .placeholder)
        } label: {
            Label("空白占位", systemImage: "square.dashed")
        }
        Divider()
        ForEach(ContextCellKind.inputKinds) { kind in
            Button {
                libraryItemKind = kind
                libraryInsertionIndex = nil
                libraryReplacementItemID = itemID
                isLibraryPresented = true
            } label: {
                Label(kind.menuLabel, systemImage: kind.icon)
            }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if !notebook.items.isEmpty {
            let outputRoundsByID = ContextOutputPresentation.roundsByItem(in: notebook.items)
            GeometryReader { editorGeometry in
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        runtimeToolbar

                        ScrollView {
                            // Dynamic NSTextView-backed editors require exact parent
                            // measurement. LazyVStack estimates off-screen heights and
                            // can overlap sections when those estimates are corrected.
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach($notebook.items) { item in
                                    let itemID = item.wrappedValue.id
                                    documentSection(
                                        item,
                                        availableRecordsByID: availableRecordsByID,
                                        outputRoundsByID: outputRoundsByID
                                    )
                                        .id(itemID)
                                        .background {
                                            ContextItemScrollAnchor(
                                                itemID: itemID,
                                                cache: documentScrollCache
                                            )
                                        }
                                }

                                Color.clear
                                    .frame(height: max(180, editorGeometry.size.height - 80))
                            }
                            .padding(.top, 12)
                            .padding(.trailing, 30)
                        }
                        .onAppear {
                            documentScrollCache.onActiveItemChange = { itemID in
                                guard navigationLockID == nil,
                                      itemID != selectedItemID else { return }
                                selectedItemID = itemID
                            }
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: navigationTargetID) { _, id in
                            guard let id else { return }
                            NSApp.keyWindow?.makeFirstResponder(nil)
                            navigationTargetID = nil

                            if !animateDocumentScroll(to: id) {
                                withAnimation(.contextNavigation) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(520))
                                    guard navigationLockID == id else { return }
                                    selectedItemID = id
                                    navigationLockID = nil
                                }
                            }
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "这个 Context 还是空的",
                systemImage: "doc.badge.plus",
                description: Text("用左下角的 + 添加一个 item。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var runtimeToolbar: some View {
        HStack(alignment: .center, spacing: 14) {
            Spacer()

            Button {
                if isModelPickerPresented {
                    dismissModelPicker()
                } else {
                    presentModelPicker()
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isRunning ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text(selectedModelName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.52))
                        .rotationEffect(.degrees(isModelPickerPresented ? 180 : 0))
                }
                .padding(.horizontal, 7)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("选择模型（配置文件：~/.fx/settings.json）")
            .overlay(alignment: .topTrailing) {
                if isModelPickerPresented {
                    modelPickerPanel
                        .offset(y: 34)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                        .zIndex(100)
                }
            }
            .zIndex(100)

            HStack(spacing: 0) {
                Button(action: performPrimaryAction) {
                    HStack(spacing: 7) {
                        if isRunning {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.75)
                                .tint(.white)
                        } else {
                            Image(systemName: primaryAction.icon)
                                .font(.system(size: 9, weight: .bold))
                        }
                        Text(primaryActionTitle)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 14)
                    .padding(.trailing, 11)
                    .frame(height: 31)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])

                Rectangle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 1, height: 15)

                Menu {
                    ForEach(ContextPrimaryAction.allCases) { action in
                        Button {
                            primaryAction = action
                            didSaveSession = false
                        } label: {
                            if primaryAction == action {
                                Label(action.rawValue, systemImage: "checkmark")
                            } else {
                                Label(action.rawValue, systemImage: action.icon)
                            }
                        }
                    }
                } label: {
                    ZStack {
                        Color.clear
                        Image(systemName: "chevron.down")
                            .symbolRenderingMode(.monochrome)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                    .frame(width: 27, height: 31)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.white)
                .fixedSize()
            }
            .background(.black)
            .clipShape(Capsule())
            .disabled(isRunning)
        }
        .padding(.trailing, 16)
        .frame(height: 58)
        .background(Color.white)
        .zIndex(20)
    }

    private var selectedModelName: String {
        let selected = notebook.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = selected.isEmpty ? fxModelSettings.defaultModel : selected
        guard let spec else { return "default model" }
        let name = fxModelSettings.displayName(for: spec)
        guard modelOption(for: spec)?.reasoningEfforts.isEmpty == false else { return name }
        return "\(name) · \((notebook.reasoning ?? .low).displayName)"
    }

    private var selectedModelSpec: String? {
        let selected = notebook.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? fxModelSettings.defaultModel : selected
    }

    private var selectedReasoningEffort: FxReasoningEffort {
        notebook.reasoning ?? .low
    }

    @ViewBuilder
    private var modelPickerPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let spec = modelPickerLevelSpec,
               let model = modelOption(for: spec),
               !model.reasoningEfforts.isEmpty {
                modelPickerRow(
                    id: "reasoning-back",
                    title: model.name,
                    detail: "Reasoning",
                    icon: "chevron.left"
                ) {
                    keepModelPickerOpenForCurrentClick()
                    withAnimation(.easeOut(duration: 0.12)) {
                        modelPickerLevelSpec = nil
                    }
                }

                modelPickerDivider

                ForEach(model.reasoningEfforts) { effort in
                    modelPickerRow(
                        id: "effort-\(model.spec)-\(effort.rawValue)",
                        title: effort.displayName,
                        selected: selectedModelSpec == model.spec && selectedReasoningEffort == effort
                    ) {
                        notebook.model = model.spec
                        notebook.reasoning = effort
                        dismissModelPicker()
                    }
                }
            } else {
                if fxModelSettings.models.isEmpty {
                    Text("No configured models")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary.opacity(0.72))
                        .padding(.horizontal, 11)
                        .frame(height: 38)
                } else {
                    ForEach(fxModelSettings.models) { model in
                        let isSelected = selectedModelSpec == model.spec
                        modelPickerRow(
                            id: "model-\(model.spec)",
                            title: model.name,
                            detail: isSelected && !model.reasoningEfforts.isEmpty
                                ? selectedReasoningEffort.displayName
                                : nil,
                            selected: isSelected,
                            showsDisclosure: !model.reasoningEfforts.isEmpty
                        ) {
                            if model.reasoningEfforts.isEmpty {
                                notebook.model = model.spec
                                dismissModelPicker()
                            } else {
                                keepModelPickerOpenForCurrentClick()
                                withAnimation(.easeOut(duration: 0.12)) {
                                    modelPickerLevelSpec = model.spec
                                }
                            }
                        }
                    }
                }

                modelPickerDivider

                if !notebook.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    modelPickerRow(
                        id: "settings-default",
                        title: "Use Settings Default",
                        icon: "arrow.uturn.backward"
                    ) {
                        notebook.model = ""
                        dismissModelPicker()
                    }
                }

                modelPickerRow(
                    id: "reload-models",
                    title: "Reload Configuration",
                    icon: "arrow.clockwise"
                ) {
                    fxModelSettings = FxModelSettings.load()
                    dismissModelPicker()
                }
            }
        }
        .padding(7)
        .frame(width: 238)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 18, x: 0, y: 8)
    }

    private var modelPickerDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.075))
            .frame(height: 1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
    }

    private func modelPickerRow(
        id: String,
        title: String,
        detail: String? = nil,
        icon: String? = nil,
        selected: Bool = false,
        showsDisclosure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.72))
                        .frame(width: 13)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(Color.black.opacity(0.84))
                        .lineLimit(1)

                    if let detail {
                        Text(detail)
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(.secondary.opacity(0.62))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.74))
                }

                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary.opacity(0.48))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: detail == nil ? 36 : 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    hoveredModelPickerRow == id
                        ? Color.black.opacity(0.055)
                        : selected ? Color.black.opacity(0.032) : Color.clear
                )
        }
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.08)) {
                if hovered {
                    hoveredModelPickerRow = id
                } else if hoveredModelPickerRow == id {
                    hoveredModelPickerRow = nil
                }
            }
        }
    }

    private func presentModelPicker() {
        modelPickerInteractionEpoch &+= 1
        modelPickerLevelSpec = nil
        withAnimation(.easeOut(duration: 0.14)) {
            isModelPickerPresented = true
        }
        modelPickerClickMonitor.start {
            let interactionEpoch = modelPickerInteractionEpoch
            DispatchQueue.main.async {
                guard isModelPickerPresented,
                      interactionEpoch == modelPickerInteractionEpoch else { return }
                dismissModelPicker()
            }
        }
    }

    private func keepModelPickerOpenForCurrentClick() {
        modelPickerInteractionEpoch &+= 1
    }

    private func dismissModelPicker() {
        modelPickerClickMonitor.stop()
        withAnimation(.easeOut(duration: 0.12)) {
            isModelPickerPresented = false
            modelPickerLevelSpec = nil
            hoveredModelPickerRow = nil
        }
    }

    private func modelOption(for spec: String) -> FxModelOption? {
        fxModelSettings.models.first(where: { $0.spec == spec })
            ?? FxModelSettings.runtimeDefaults.models.first(where: { $0.spec == spec })
    }

    private var primaryActionTitle: String {
        if isRunning { return "Running" }
        if primaryAction == .save && didSaveSession { return "Saved" }
        return primaryAction.rawValue
    }

    private func performPrimaryAction() {
        dismissModelPicker()
        switch primaryAction {
        case .run:
            runContext()
        case .save:
            saveCurrentSession()
        }
    }

    private func saveCurrentSession() {
        do {
            let session = try store.upsertSession(notebook: notebook, sessionID: activeSessionID)
            activeSessionID = session.id
            shouldKeepSessionOnClose = true
            saveFeedbackGeneration += 1
            let generation = saveFeedbackGeneration
            withAnimation(.easeOut(duration: 0.16)) {
                didSaveSession = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                guard generation == saveFeedbackGeneration else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    didSaveSession = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func documentSection(
        _ item: Binding<ContextNotebookItem>,
        availableRecordsByID: [UUID: CaptureRecord],
        outputRoundsByID: [UUID: [ContextRunRound]]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(item.wrappedValue.kind.menuLabel)
                .font(.system(size: 14))
                .foregroundStyle(.secondary.opacity(0.64))

            selectedItemEditor(
                item,
                availableRecordsByID: availableRecordsByID,
                outputRoundsByID: outputRoundsByID
            )

            Rectangle()
                .fill(.black.opacity(0.055))
                .frame(height: 1)
                .padding(.top, item.wrappedValue.kind == .system || item.wrappedValue.kind == .query ? 4 : 12)
        }
        .padding(.bottom, 54)
    }

    @ViewBuilder
    private func selectedItemEditor(
        _ item: Binding<ContextNotebookItem>,
        availableRecordsByID: [UUID: CaptureRecord],
        outputRoundsByID: [UUID: [ContextRunRound]]
    ) -> some View {
        let value = item.wrappedValue
        if value.kind == .context,
           let id = value.sourceRecordID,
           let record = availableRecordsByID[id] {
            referencedRecordEditor(item, record: record)
        } else {
            switch value.kind {
            case .query:
                queryEditor(item)
            case .system, .context:
                simpleTextEditor(item)
            case .tool:
                definitionEditor(
                    item,
                    titlePrompt: "Tool name",
                    detailPrompt: "What this tool can do",
                    bodyPrompt: nil
                )
            case .skill:
                definitionEditor(
                    item,
                    titlePrompt: "Skill name",
                    detailPrompt: "When the agent should use this skill",
                    bodyPrompt: "Complete skill instructions…"
                )
            case .subagent:
                definitionEditor(
                    item,
                    titlePrompt: "Subagent name",
                    detailPrompt: "What this subagent handles",
                    bodyPrompt: "Subagent system instructions…"
                )
            case .output:
                outputEditor(value, visibleRounds: outputRoundsByID[value.id] ?? [])
            case .placeholder:
                placeholderEditor(item)
            }
        }
    }

    private func simpleTextEditor(_ item: Binding<ContextNotebookItem>) -> some View {
        let itemID = item.wrappedValue.id
        return VStack(alignment: .leading, spacing: 0) {
            TextField(
                item.wrappedValue.kind == .query ? "Query title…" : item.wrappedValue.kind.defaultTitle,
                text: item.title,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 20))
            .lineLimit(1...3)
            .focused($focusedEditorField, equals: .title(itemID))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                focusEditor(.title(itemID))
            })
            .padding(.top, 9)

            markdownBodyEditor(
                text: item.body,
                prompt: item.wrappedValue.kind == .system
                    ? "System instructions…"
                    : "Paste or write context…",
                itemID: itemID
            )
            .padding(.top, 14)
        }
    }

    @ViewBuilder
    private func markdownBodyEditor(
        text: Binding<String>,
        prompt: String,
        itemID: UUID
    ) -> some View {
        let focus = ContextEditorFocus.body(itemID)
        if focusedEditorField == focus || text.wrappedValue.isEmpty {
            cleanTextEditor(
                text: text,
                prompt: prompt,
                minHeight: 28,
                focus: focus
            )
        } else {
            let preview = markdownPreview(text.wrappedValue, itemID: itemID)
            VStack(alignment: .leading, spacing: 0) {
                ContextMarkdownDocument(
                    markdown: preview.markdown,
                    baseFontSize: 13,
                    tone: .secondary,
                    layout: .editorDocument
                )
                .equatable()

                if preview.canToggle {
                    markdownExpansionButton(
                        itemID: itemID,
                        totalLines: preview.totalLines,
                        isExpanded: preview.isExpanded
                    )
                    .padding(.top, 10)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button {
                    focusEditor(focus)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.46))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Markdown")
            }
        }
    }

    private func queryEditor(_ item: Binding<ContextNotebookItem>) -> some View {
        let itemID = item.wrappedValue.id
        return VStack(alignment: .leading, spacing: 0) {
            TextField(
                "",
                text: item.body,
                prompt: Text("Ask the agent…").foregroundStyle(.secondary.opacity(0.45)),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 20))
            .lineSpacing(6)
            .lineLimit(1...16)
            .frame(minHeight: 28, alignment: .top)
            .focused($focusedEditorField, equals: .body(itemID))
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                focusEditor(.body(itemID))
            })

            if item.wrappedValue.attachments?.isEmpty == false {
                queryAttachmentStrip(item)
                    .padding(.top, 10)
            }
        }
        .onPasteCommand(of: [.image]) { _ in
            pasteImageIntoQuery(itemID)
        }
        .padding(.top, 12)
    }

    private func queryAttachmentStrip(_ item: Binding<ContextNotebookItem>) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(item.wrappedValue.attachments ?? []) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = NSImage(data: attachment.data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Color.secondary.opacity(0.06)
                                    .overlay {
                                        Image(systemName: "photo")
                                            .font(.system(size: 14))
                                            .foregroundStyle(.secondary.opacity(0.45))
                                    }
                            }
                        }
                        .frame(width: 76, height: 56)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        Button {
                            item.wrappedValue.attachments?.removeAll(where: { $0.id == attachment.id })
                            if item.wrappedValue.attachments?.isEmpty == true {
                                item.wrappedValue.attachments = nil
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.primary.opacity(0.66))
                                .frame(width: 17, height: 17)
                                .background(.white.opacity(0.9), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .accessibilityLabel("Remove \(attachment.name)")
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 56)
    }

    private func pasteImageIntoQuery(_ itemID: UUID) {
        guard let index = notebook.items.firstIndex(where: { $0.id == itemID && $0.kind == .query }),
              let image = NSImage(pasteboard: .general) else { return }
        let existingCount = notebook.items[index].attachments?.count ?? 0
        guard let data = queryImageData(from: image) else {
            errorMessage = "无法读取剪贴板中的图片。"
            return
        }
        guard data.count <= 16 * 1_024 * 1_024 else {
            errorMessage = "图片处理后仍超过 16 MB，请粘贴尺寸更小的图片。"
            return
        }
        let attachment = ContextNotebookAttachment(
            name: "pasted-image-\(existingCount + 1).png",
            mediaType: "image/png",
            data: data
        )
        notebook.items[index].attachments = (notebook.items[index].attachments ?? []) + [attachment]
    }

    private func queryImageData(from image: NSImage, maximumPixelDimension: Int = 2_048) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff) else { return nil }
        let largestDimension = max(source.pixelsWide, source.pixelsHigh)
        guard largestDimension > maximumPixelDimension else {
            return source.representation(using: .png, properties: [:])
        }

        let scale = CGFloat(maximumPixelDimension) / CGFloat(largestDimension)
        let width = max(1, Int((CGFloat(source.pixelsWide) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.pixelsHigh) * scale).rounded()))
        guard let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: resized) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return resized.representation(using: .png, properties: [:])
    }

    private func definitionEditor(
        _ item: Binding<ContextNotebookItem>,
        titlePrompt: String,
        detailPrompt: String,
        bodyPrompt: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(titlePrompt, text: item.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 23))
                .lineLimit(1...3)
                .padding(.top, 9)

            TextField(detailPrompt, text: item.detail, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.secondary.opacity(0.72))
                .lineSpacing(5)
                .lineLimit(2...4)
                .padding(.top, 14)

            if let bodyPrompt {
                cleanTextEditor(text: item.body, prompt: bodyPrompt, minHeight: 28)
                    .padding(.top, 42)
            }
        }
    }

    @ViewBuilder
    private func cleanTextEditor(
        text: Binding<String>,
        prompt: String,
        minHeight: CGFloat,
        focus: ContextEditorFocus? = nil
    ) -> some View {
        let focusBinding = focus.map { target in
            Binding(
                get: { focusedEditorField == target },
                set: { focused in
                    if focused {
                        focusedEditorField = target
                    } else if focusedEditorField == target {
                        focusedEditorField = nil
                    }
                }
            )
        }
        ContextFastTextEditor(
            text: text,
            prompt: prompt,
            minHeight: minHeight,
            maximumLines: 50,
            isFocused: focusBinding
        )
        .frame(minHeight: minHeight, alignment: .top)
    }

    private func focusEditor(_ field: ContextEditorFocus) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKey()
        focusedEditorField = field
    }

    private func markdownPreview(
        _ markdown: String,
        itemID: UUID,
        lineLimit: Int = 10
    ) -> (markdown: String, totalLines: Int, canToggle: Bool, isExpanded: Bool) {
        let isExpanded = expandedMarkdownItemIDs.contains(itemID)
        return markdownPreviewCache.preview(
            for: markdown,
            itemID: itemID,
            lineLimit: lineLimit,
            isExpanded: isExpanded
        )
    }

    private func markdownExpansionButton(
        itemID: UUID,
        totalLines: Int,
        isExpanded: Bool
    ) -> some View {
        Button(isExpanded ? "Show less" : "Show all · \(totalLines) lines") {
            if isExpanded {
                expandedMarkdownItemIDs.remove(itemID)
            } else {
                expandedMarkdownItemIDs.insert(itemID)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary.opacity(0.62))
    }

    private func referencedRecordEditor(
        _ item: Binding<ContextNotebookItem>,
        record: CaptureRecord
    ) -> some View {
        let preview = item.wrappedValue.body.isEmpty
            ? store.context(for: record)
            : item.wrappedValue.body
        let visiblePreview = markdownPreview(preview, itemID: item.wrappedValue.id)
        return VStack(alignment: .leading, spacing: 0) {
            Text(item.wrappedValue.title.isEmpty ? record.title : item.wrappedValue.title)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.top, 9)

            VStack(alignment: .leading, spacing: 0) {
                ContextMarkdownDocument(
                    markdown: visiblePreview.markdown,
                    baseFontSize: 13,
                    tone: .secondary,
                    layout: .editorDocument
                )
                .equatable()

                if visiblePreview.canToggle {
                    markdownExpansionButton(
                        itemID: item.wrappedValue.id,
                        totalLines: visiblePreview.totalLines,
                        isExpanded: visiblePreview.isExpanded
                    )
                    .padding(.top, 10)
                }
            }
            .padding(.top, 22)

            if store.contextMediaURL(for: record) != nil {
                recordVisual(record)
                    .padding(.top, 56)
            }
        }
    }

    private func recordVisual(_ record: CaptureRecord) -> some View {
        ZStack {
            if let url = store.contextMediaURL(for: record) {
                Color.black
                CachedLocalImage(url: url, maxPixelSize: 1_800, contentMode: .fill, showsProgress: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                switch record.kind {
                case .text:
                    ZStack(alignment: .topLeading) {
                        Color(red: 0.94, green: 0.93, blue: 0.89)
                        VStack(alignment: .leading, spacing: 26) {
                            Image(systemName: "quote.opening").font(.system(size: 24, weight: .semibold))
                            Text(store.originalTextContent(for: record) ?? record.title)
                                .font(.system(size: 24, weight: .semibold, design: .serif))
                                .lineLimit(8)
                        }
                        .foregroundStyle(.black.opacity(0.86))
                        .padding(48)
                    }
                case .link:
                    ZStack {
                        LinearGradient(colors: [.black.opacity(0.88), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                        VStack(spacing: 18) {
                            Image(systemName: "link").font(.system(size: 28, weight: .light))
                            Text(record.sourceURL ?? record.title)
                                .font(.system(size: 19, weight: .medium))
                                .multilineTextAlignment(.center)
                                .lineLimit(4)
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(48)
                    }
                case .video:
                    ZStack {
                        Color.black.opacity(0.94)
                        Image(systemName: "play.fill")
                            .font(.system(size: 31, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                case .image, .browserSnapshot:
                    Color.black.opacity(0.04)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(1.62, contentMode: .fit)
        .clipped()
        .overlay { Rectangle().stroke(.black.opacity(0.055), lineWidth: 1) }
    }

    private func outputEditor(
        _ item: ContextNotebookItem,
        visibleRounds: [ContextRunRound]
    ) -> some View {
        let hasVisibleActivity = visibleRounds.contains(where: { !($0.steps ?? []).isEmpty })
        return VStack(alignment: .leading, spacing: 0) {
            Text("Agent output")
                .font(.system(size: 20))
                .padding(.top, 9)

            if let run = item.run {
                HStack(spacing: 8) {
                    Circle()
                        .fill(run.status == "running" ? Color.secondary.opacity(0.48) : run.status == "completed" ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text(run.status)
                    if let model = run.model { Text("· \(model)") }
                    if let input = run.usage?.input { Text("· Input \(input)") }
                    if let output = run.usage?.output { Text("· Output \(output)") }
                    if let tokens = run.totalTokens { Text("· Total \(tokens)") }
                    Text("· Saved to Session")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary.opacity(0.68))
                .padding(.top, 14)

                if item.id == liveOutputID, run.status == "running" {
                    ContextLiveRunView(store: liveActivityStore)
                        .padding(.top, 30)
                } else if hasVisibleActivity {
                    ContextPersistedRunActivity(rounds: visibleRounds)
                        .equatable()
                        .padding(.top, 30)
                }

                if !run.final.isEmpty, item.id != liveOutputID {
                    ContextMarkdownOutput(markdown: run.final)
                        .equatable()
                        .padding(.top, hasVisibleActivity ? 26 : 54)
                }
                if let error = run.error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.78))
                        .padding(.top, 30)
                }
            }
        }
    }

    private func placeholderEditor(_ item: Binding<ContextNotebookItem>) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("Empty placeholder").font(.system(size: 23)).padding(.top, 9)
            Text("选择这个占位 item 的类型")
                .font(.system(size: 15))
                .foregroundStyle(.secondary.opacity(0.72))
            HStack(spacing: 10) {
                ForEach([ContextCellKind.context, .query, .system]) { kind in
                    Button(kind.label) {
                        item.wrappedValue.kind = kind
                        item.wrappedValue.title = kind == .query ? "" : kind.defaultTitle
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func addItem(_ kind: ContextCellKind, at insertionIndex: Int?) {
        let item = ContextNotebookItem(
            kind: kind,
            title: kind == .query ? "" : kind == .tool ? "echo" : kind.defaultTitle,
            detail: kind == .tool ? "Return the supplied text unchanged." : ""
        )
        let index = min(max(0, insertionIndex ?? notebook.items.count), notebook.items.count)
        notebook.items.insert(item, at: index)
        navigationLockID = item.id
        selectedItemID = item.id
        navigationTargetID = item.id
    }

    private func notebookItem(
        for record: CaptureRecord,
        id: UUID = UUID()
    ) -> ContextNotebookItem {
        let space = record.space ?? .context
        let kind: ContextCellKind = switch space {
        case .system: .system
        case .context: .context
        case .query: .query
        case .tool: .tool
        case .skill: .skill
        case .subagent: .subagent
        case .session: .context
        }
        let configuration = record.agentConfiguration
        return ContextNotebookItem(
            id: id,
            kind: kind,
            title: kind == .query ? "" : record.title,
            body: kind == .context ? store.context(for: record) : store.originalTextContent(for: record) ?? record.text ?? "",
            detail: record.itemDescription ?? "",
            sourceRecordID: kind == .context ? record.id : nil,
            tools: configuration?.tools,
            skills: configuration?.skills,
            model: configuration?.model,
            fork: configuration?.fork
        )
    }

    private func addRecords(_ records: [CaptureRecord]) {
        guard !records.isEmpty else { return }

        if let replacementID = libraryReplacementItemID {
            guard let index = notebook.items.firstIndex(where: { $0.id == replacementID }) else {
                finishLibrarySelection()
                return
            }
            NSApp.keyWindow?.makeFirstResponder(nil)
            notebook.items[index] = notebookItem(for: records[0], id: replacementID)
            libraryReplacementItemID = nil
            libraryInsertionIndex = nil
            navigationLockID = replacementID
            selectedItemID = replacementID
            navigationTargetID = replacementID
            return
        }

        let index = min(max(0, libraryInsertionIndex ?? notebook.items.count), notebook.items.count)
        let newItems = records.map { notebookItem(for: $0) }
        notebook.items.insert(contentsOf: newItems, at: index)
        libraryInsertionIndex = nil
        guard let firstItem = newItems.first else { return }
        navigationLockID = firstItem.id
        selectedItemID = firstItem.id
        navigationTargetID = firstItem.id
    }

    private func replaceItem(_ id: UUID, with kind: ContextCellKind) {
        guard let index = notebook.items.firstIndex(where: { $0.id == id }) else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        let replacement = ContextNotebookItem(
            id: id,
            kind: kind,
            title: kind == .query ? "" : kind == .tool ? "echo" : kind.defaultTitle,
            detail: kind == .tool ? "Return the supplied text unchanged." : ""
        )
        notebook.items[index] = replacement
        navigationLockID = id
        selectedItemID = id
        navigationTargetID = id
    }

    private func finishLibrarySelection() {
        libraryInsertionIndex = nil
        libraryReplacementItemID = nil
    }

    private func deleteItem(_ id: UUID) {
        guard let index = notebook.items.firstIndex(where: { $0.id == id }) else { return }
        let replacementID: UUID? = {
            guard selectedItemID == id else { return selectedItemID }
            if notebook.items.indices.contains(index + 1) {
                return notebook.items[index + 1].id
            }
            if notebook.items.indices.contains(index - 1) {
                return notebook.items[index - 1].id
            }
            return nil
        }()

        // End any edit/navigation transaction that still references the row before
        // mutating the collection. SwiftUI may render a removed row for one more pass.
        NSApp.keyWindow?.makeFirstResponder(nil)
        scrollAnimationDriver.stop()
        if navigationTargetID == id { navigationTargetID = nil }
        if navigationLockID == id { navigationLockID = nil }
        if hoveredItemID == id { hoveredItemID = nil }
        if draggedItemID == id { draggedItemID = nil }
        expandedMarkdownItemIDs.remove(id)
        markdownPreviewCache.removeValue(for: id)
        selectedItemID = replacementID
        notebook.items.remove(at: index)
    }

    /// A UUID-based binding remains valid during SwiftUI's removal transition. Array
    /// element bindings created by `ForEach($items)` retain an old index and can trap
    /// after an item is deleted while its view is still completing a render pass.
    private func safeBinding(forID id: UUID) -> Binding<ContextNotebookItem> {
        Binding(
            get: {
                notebook.items.first(where: { $0.id == id })
                    ?? ContextNotebookItem(id: id, kind: .placeholder)
            },
            set: { updated in
                guard let index = notebook.items.firstIndex(where: { $0.id == id }) else { return }
                notebook.items[index] = updated
            }
        )
    }

    private func moveItem(from index: Int, offset: Int) {
        let destination = index + offset
        guard notebook.items.indices.contains(index), notebook.items.indices.contains(destination) else { return }
        let item = notebook.items.remove(at: index)
        notebook.items.insert(item, at: destination)
    }

    private func loadNotebook() {
        fxModelSettings = FxModelSettings.load()
        guard !isLoaded, let collection = store.selectedCollection else { return }
        if let initialSessionID {
            do {
                notebook = try store.notebook(forSession: initialSessionID)
                activeSessionID = initialSessionID
                shouldKeepSessionOnClose = true
            } catch {
                notebook = ContextNotebook.fresh(title: collection.name)
                errorMessage = error.localizedDescription
            }
        } else {
            notebook = ContextNotebook.fresh(title: collection.name)
        }
        selectedItemID = notebook.items.first?.id
        isLoaded = true
    }

    private func runContext() {
        guard !isRunning, let runtimeWorkingDirectoryURL else { return }
        guard notebook.items.contains(where: {
            $0.hasQueryContent
        }) else {
            errorMessage = ContextNotebookError.noQuery.localizedDescription
            return
        }
        do {
            let session = try store.upsertSession(notebook: notebook, sessionID: activeSessionID)
            activeSessionID = session.id
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let records = availableRecords
        let contexts = Dictionary(uniqueKeysWithValues: records.map { ($0.id, store.context(for: $0)) })
        let mediaURLs = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            store.contextMediaURL(for: record).map { (record.id, $0) }
        })
        let payload = ContextRuntimePayload(
            notebook: notebook,
            collectionURL: runtimeWorkingDirectoryURL,
            records: records,
            contexts: contexts,
            mediaURLs: mediaURLs
        )

        let startedAt = Date()
        let outputID = UUID()
        let runningResult = ContextRunResult(
            status: "running",
            runtime: "pi",
            model: fxModelSettings.resolvedModel(explicitModel: notebook.model),
            final: "",
            events: [],
            startedAt: startedAt,
            endedAt: startedAt
        )
        let output = ContextNotebookItem(
            id: outputID,
            kind: .output,
            title: "Output",
            body: "",
            run: runningResult
        )
        notebook.items.append(output)
        liveActivityStore.reset()
        liveOutputID = outputID
        navigationLockID = outputID
        selectedItemID = outputID
        navigationTargetID = outputID
        isRunning = true

        Task { @MainActor in
            defer {
                isRunning = false
                artifactRefreshRevision &+= 1
            }
            do {
                let result = try await ContextPiRunner.run(payload) { event in
                    guard liveOutputID == outputID else { return }
                    liveActivityStore.apply(event)
                }
                guard let index = notebook.items.firstIndex(where: { $0.id == outputID }) else { return }
                notebook.items[index].body = result.final
                notebook.items[index].run = result
                liveOutputID = nil
                selectedItemID = outputID
                let session = try store.upsertSession(notebook: notebook, sessionID: activeSessionID)
                activeSessionID = session.id
                compactInMemoryRunState(keepingMessagesIn: outputID)
            } catch {
                let failed = ContextRunResult(
                    status: "failed",
                    runtime: "pi",
                    model: fxModelSettings.resolvedModel(explicitModel: notebook.model),
                    error: error.localizedDescription,
                    final: "",
                    events: [],
                    startedAt: startedAt,
                    endedAt: Date()
                )
                if let index = notebook.items.firstIndex(where: { $0.id == outputID }) {
                    notebook.items[index].run = failed
                }
                liveOutputID = nil
                if let session = try? store.upsertSession(notebook: notebook, sessionID: activeSessionID) {
                    activeSessionID = session.id
                }
                compactInMemoryRunState(keepingMessagesIn: outputID)
                errorMessage = error.localizedDescription
            }
        }
    }

    /// UI rendering only needs rounds and the final answer. Keep continuation
    /// messages on the newest output, while raw events remain in events.json.
    private func compactInMemoryRunState(keepingMessagesIn outputID: UUID) {
        for index in notebook.items.indices where notebook.items[index].kind == .output {
            notebook.items[index].run?.events = nil
            if notebook.items[index].id != outputID {
                notebook.items[index].run?.messages = nil
            }
        }
    }

    private func sidebarTitle(for item: ContextNotebookItem) -> String {
        if item.sourceRecordID != nil { return item.title }
        if item.kind == .output { return "Output" }
        if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return item.title }
        return item.kind.defaultTitle
    }

    /// Scrolls the document with the exact quadratic Bézier position equation:
    /// B(t) = (1-t)^2 * from + 2(1-t)t * control + t^2 * to.
    @discardableResult
    private func animateDocumentScroll(to itemID: UUID) -> Bool {
        guard let scrollView = documentScrollCache.resolvedScrollView,
              let relativeTargetY = documentScrollCache.relativePosition(for: itemID),
              let documentView = scrollView.documentView else { return false }

        let clipView = scrollView.contentView
        let from = clipView.bounds.origin.y
        let maximum = max(0, documentView.bounds.height - clipView.bounds.height)
        let to = min(max(from + relativeTargetY, 0), maximum)
        let control = from + (to - from) * 0.82
        let duration: CFTimeInterval = 0.46
        let startedAt = CACurrentMediaTime()

        scrollAnimationDriver.start(for: scrollView) { timestamp in
            let t = min(max((timestamp - startedAt) / duration, 0), 1)
            let inverse = 1 - t
            let position = inverse * inverse * from
                + 2 * inverse * t * control
                + t * t * to

            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: position))
            scrollView.reflectScrolledClipView(clipView)

            guard t >= 1 else { return false }
            if navigationLockID == itemID {
                selectedItemID = itemID
                navigationLockID = nil
            }
            return true
        }
        return true
    }

    private func previewURL(for record: CaptureRecord) -> URL? {
        let gallery = store.galleryMediaURLs(for: record)
        return gallery.preview ?? store.thumbnailURL(for: record) ?? {
            switch record.kind {
            case .image, .browserSnapshot: store.fileURL(for: record)
            case .text, .link, .video: nil
            }
        }()
    }

    private func contextOverview(for record: CaptureRecord) -> String {
        if let text = store.originalTextContent(for: record), !text.isEmpty {
            return text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: " ")
                .nonemptyPrefix(560) ?? ""
        }
        return record.sourceURL ?? ""
    }

    private func requestCloseEditor() {
        guard !isRunning else { return }
        isCloseConfirmationPresented = true
    }

    private func saveAndCloseEditor() {
        do {
            let session = try store.upsertSession(notebook: notebook, sessionID: activeSessionID)
            activeSessionID = session.id
            shouldKeepSessionOnClose = true
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func discardAndCloseEditor() {
        do {
            try discardSessionDraftIfNeeded()
            onClose()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func discardSessionDraftIfNeeded() throws {
        guard !shouldKeepSessionOnClose, let activeSessionID else { return }
        try store.discardSessionDraft(activeSessionID)
        self.activeSessionID = nil
    }
}

private struct ContextLibraryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CaptureStore
    let itemType: CaptureSpace
    let records: [CaptureRecord]
    let isReplacing: Bool
    let onSelect: ([CaptureRecord]) -> Void
    @State private var search = ""
    @State private var selectedRecordIDs: Set<UUID> = []

    private var filtered: [CaptureRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.tags ?? []).contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || ($0.itemDescription?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择 \(itemType.displayName) Item").font(.system(size: 20, weight: .semibold))
                    Text(isReplacing
                        ? "从 Library 中选择一个 \(itemType.displayName)，替换当前 Item。"
                        : "可多选；确认后按列表顺序插入到当前位置。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                if !isReplacing {
                    Button(selectedRecordIDs.isEmpty ? "添加" : "添加 \(selectedRecordIDs.count) 项") {
                        onSelect(records.filter { selectedRecordIDs.contains($0.id) })
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
                    .disabled(selectedRecordIDs.isEmpty)
                }
            }
            .padding(22)

            TextField("搜索收藏", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)

            ScrollView {
                Group {
                    if filtered.isEmpty {
                        ContentUnavailableView(
                            "还没有 \(itemType.displayName) Item",
                            systemImage: itemType.icon,
                            description: Text("先在 Library 的 \(itemType.displayName) 分类中创建一个 Item。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 390)
                    } else {
                        LazyVStack(spacing: 1) {
                            ForEach(filtered) { record in
                                Button {
                                    if isReplacing {
                                        onSelect([record])
                                        dismiss()
                                    } else if selectedRecordIDs.contains(record.id) {
                                        selectedRecordIDs.remove(record.id)
                                    } else {
                                        selectedRecordIDs.insert(record.id)
                                    }
                                } label: {
                                    HStack(spacing: 13) {
                                        Group {
                                            if let coverURL = coverPreviewURL(for: record) {
                                                CachedLocalImage(
                                                    url: coverURL,
                                                    maxPixelSize: 320,
                                                    contentMode: .fill
                                                )
                                            } else {
                                                Image(systemName: record.kind.contextIcon)
                                                    .font(.system(size: 17, weight: .light))
                                                    .foregroundStyle(.black.opacity(0.66))
                                            }
                                        }
                                        .frame(width: 52, height: 42)
                                        .background(.black.opacity(0.045))
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(record.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(.black)
                                                .lineLimit(1)
                                            Text((record.space ?? .context).displayName)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if isReplacing {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Image(systemName: selectedRecordIDs.contains(record.id)
                                                ? "checkmark.circle.fill"
                                                : "circle")
                                                .font(.system(size: 17, weight: .regular))
                                                .foregroundStyle(selectedRecordIDs.contains(record.id)
                                                    ? Color.black
                                                    : Color.secondary.opacity(0.45))
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 62)
                                    .background(selectedRecordIDs.contains(record.id)
                                        ? Color.black.opacity(0.045)
                                        : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(width: 520, height: 620)
        .background(Color.white)
        .onAppear {
            selectedRecordIDs.removeAll(keepingCapacity: true)
        }
    }

    private func coverPreviewURL(for record: CaptureRecord) -> URL? {
        let gallery = store.galleryMediaURLs(for: record)
        if let preview = gallery.preview { return preview }
        if let thumbnail = store.thumbnailURL(for: record) { return thumbnail }
        switch record.kind {
        case .image, .browserSnapshot:
            return store.fileURL(for: record)
        case .text, .link, .video:
            return nil
        }
    }
}

private extension ContextCellKind {
    static let inputKinds: [ContextCellKind] = [.system, .context, .query, .tool, .skill, .subagent]
    var label: String { rawValue.uppercased() }

    var captureSpace: CaptureSpace? {
        switch self {
        case .system: .system
        case .context: .context
        case .query: .query
        case .tool: .tool
        case .skill: .skill
        case .subagent: .subagent
        case .output, .placeholder: nil
        }
    }

    var menuLabel: String {
        switch self {
        case .system: "System"
        case .context: "Context"
        case .query: "Query"
        case .tool: "Tool"
        case .skill: "Skill"
        case .subagent: "Subagent"
        case .output: "Output"
        case .placeholder: "Placeholder"
        }
    }

    var defaultTitle: String { self == .placeholder ? "Empty placeholder" : menuLabel }

    var icon: String {
        switch self {
        case .system: "command"
        case .context: "doc.text"
        case .query: "bubble.left"
        case .tool: "wrench.and.screwdriver"
        case .skill: "sparkles"
        case .subagent: "person.2"
        case .output: "arrow.turn.down.right"
        case .placeholder: "square.dashed"
        }
    }
}

private extension CaptureRecord.Kind {
    var contextIcon: String {
        switch self {
        case .text: "text.quote"
        case .link: "link"
        case .video: "play.rectangle"
        case .image: "photo"
        case .browserSnapshot: "globe"
        }
    }
}

private extension String {
    func nonemptyPrefix(_ length: Int) -> String? {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return clean.isEmpty ? nil : String(clean.prefix(length))
    }
}

/// NSTextView keeps large prompts responsive while preserving the visual
/// contract of the former vertically-growing SwiftUI TextField. The native
/// text system edits its storage in place instead of reconstructing and
/// remeasuring a 10–20 KB String on every keystroke.
private struct ContextFastTextEditor: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let minHeight: CGFloat
    let maximumLines: Int
    let isFocused: Binding<Bool>?

    private let font = NSFont.systemFont(ofSize: 13)
    private let lineSpacing: CGFloat = 4

    private var contentColor: NSColor {
        guard let resolved = NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB) else {
            return NSColor.secondaryLabelColor
        }
        return resolved.withAlphaComponent(resolved.alphaComponent * 0.76)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let textView = ContextPromptTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = font
        textView.textColor = contentColor
        textView.insertionPointColor = .controlAccentColor
        textView.placeholder = prompt
        textView.placeholderFont = font
        textView.placeholderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        textView.string = text
        applyTypography(to: textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }

        textView.placeholder = prompt
        textView.placeholderFont = font
        textView.placeholderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        textView.font = font
        textView.textColor = contentColor

        if textView.string != text {
            let selection = textView.selectedRange()
            context.coordinator.isApplyingExternalText = true
            textView.string = text
            applyTypography(to: textView)
            let safeLocation = min(selection.location, (text as NSString).length)
            let safeLength = min(selection.length, (text as NSString).length - safeLocation)
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
            context.coordinator.isApplyingExternalText = false
            context.coordinator.invalidateMeasurement()
            scrollView.invalidateIntrinsicContentSize()
        }

        if isFocused?.wrappedValue == true,
           textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, context.coordinator.parent.isFocused?.wrappedValue == true else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: NSScrollView,
        context: Context
    ) -> CGSize? {
        guard let textView = context.coordinator.textView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return nil }

        let width = max(1, proposal.width ?? scrollView.bounds.width)
        if context.coordinator.measuredRevision == context.coordinator.textRevision,
           abs(context.coordinator.measuredWidth - width) < 0.5,
           let cachedSize = context.coordinator.measuredSize {
            return cachedSize
        }

        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)

        let lineHeight = layoutManager.defaultLineHeight(for: font) + lineSpacing
        let contentHeight = max(lineHeight, ceil(layoutManager.usedRect(for: textContainer).height))
        let maximumHeight = ceil(lineHeight * CGFloat(maximumLines))
        let viewportHeight = min(max(contentHeight, minHeight), maximumHeight)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(contentHeight, viewportHeight))
        let measuredSize = CGSize(width: width, height: viewportHeight)
        context.coordinator.measuredWidth = width
        context.coordinator.measuredRevision = context.coordinator.textRevision
        context.coordinator.measuredSize = measuredSize
        return measuredSize
    }

    private func applyTypography(to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: contentColor,
            .paragraphStyle: paragraph
        ]
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        if fullRange.length > 0 {
            textView.textStorage?.setAttributes(attributes, range: fullRange)
        }
        textView.typingAttributes = attributes
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ContextFastTextEditor
        weak var textView: ContextPromptTextView?
        weak var scrollView: NSScrollView?
        var isApplyingExternalText = false
        var textRevision = 0
        var measuredRevision = -1
        var measuredWidth: CGFloat = -1
        var measuredSize: CGSize?

        init(parent: ContextFastTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused?.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalText, let textView else { return }
            invalidateMeasurement()
            parent.text = textView.string
            scrollView?.invalidateIntrinsicContentSize()
        }

        func invalidateMeasurement() {
            textRevision &+= 1
            measuredSize = nil
        }
    }
}

private final class ContextPromptTextView: NSTextView {
    var placeholder = "" { didSet { if oldValue != placeholder { needsDisplay = true } } }
    var placeholderFont: NSFont = .systemFont(ofSize: 15)
    var placeholderColor: NSColor = .placeholderTextColor

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        (placeholder as NSString).draw(
            with: bounds,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: placeholderFont,
                .foregroundColor: placeholderColor,
                .paragraphStyle: paragraph
            ]
        )
    }
}

/// A stable TextKit-backed surface for large referenced Contexts. SwiftUI's
/// `Text` may remeasure the whole value whenever surrounding editor state
/// changes; this view lays it out once per text/width pair and reuses the result.
private struct ContextFastReadOnlyText: NSViewRepresentable, Equatable {
    let text: String

    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let lineSpacing: CGFloat = 5

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.font = font
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.76)
        textView.string = text
        applyTypography(to: textView)
        context.coordinator.text = text
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard context.coordinator.text != text else { return }
        textView.string = text
        applyTypography(to: textView)
        context.coordinator.text = text
        context.coordinator.measuredWidth = -1
        context.coordinator.measuredSize = nil
        textView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else { return nil }
        let width = max(1, proposal.width ?? textView.bounds.width)
        if abs(context.coordinator.measuredWidth - width) < 0.5,
           let measuredSize = context.coordinator.measuredSize {
            return measuredSize
        }

        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let lineHeight = layoutManager.defaultLineHeight(for: font) + lineSpacing
        let height = max(lineHeight, ceil(layoutManager.usedRect(for: textContainer).height))
        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let size = CGSize(width: width, height: height)
        context.coordinator.measuredWidth = width
        context.coordinator.measuredSize = size
        return size
    }

    private func applyTypography(to textView: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.76),
            .paragraphStyle: paragraph
        ]
        let length = (textView.string as NSString).length
        if length > 0 {
            textView.textStorage?.setAttributes(attributes, range: NSRange(location: 0, length: length))
        }
    }

    final class Coordinator {
        var text = ""
        var measuredWidth: CGFloat = -1
        var measuredSize: CGSize?
    }
}

private struct ContextLiveRunView: View {
    @ObservedObject var store: ContextLiveActivityStore

    var body: some View {
        // Live runs usually contain tens of entries. During token streaming an
        // eager stack is cheaper than recomputing LazyStack placements every frame.
        VStack(alignment: .leading, spacing: 18) {
            ForEach(store.activity.entries) { entry in
                ContextActivityEntryView(entry: entry)
                    .equatable()
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.black.opacity(0.66))
                    .frame(width: 14, height: 14)
                ContextShimmerText(text: store.activity.activeText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContextPersistedRunActivity: View, Equatable {
    let rounds: [ContextRunRound]

    private var entries: [ContextLiveActivity.Entry] {
        rounds.flatMap { round in
            var roundEntries: [ContextLiveActivity.Entry] = []
            for (index, step) in (round.steps ?? []).enumerated() {
                let id = "round-\(round.index)-\(index)-\(step.id ?? step.type)"
                switch step.type {
                case "reasoning":
                    roundEntries.append(ContextLiveActivity.Entry(
                        id: id,
                        kind: .reasoning,
                        title: "Thinking",
                        detail: step.text ?? ""
                    ))
                case "tool-call":
                    roundEntries.append(ContextLiveActivity.Entry(
                        id: id,
                        kind: .toolCall,
                        title: step.name ?? "tool",
                        detail: step.arguments?.displayText ?? "",
                        toolName: step.name ?? "tool",
                        payload: step.arguments,
                        toolCallID: step.id
                    ))
                case "tool-result":
                    if let callIndex = roundEntries.lastIndex(where: {
                        $0.kind == .toolCall && $0.toolCallID == step.id
                    }) {
                        roundEntries[callIndex].resultDetail = step.text ?? ""
                        roundEntries[callIndex].resultPayload = step.details
                        roundEntries[callIndex].isError = step.isError ?? false
                    } else {
                        roundEntries.append(ContextLiveActivity.Entry(
                            id: id,
                            kind: .toolCall,
                            title: step.name ?? "tool",
                            detail: "",
                            toolName: step.name ?? "tool",
                            toolCallID: step.id,
                            resultDetail: step.text ?? "",
                            resultPayload: step.details,
                            isError: step.isError ?? false
                        ))
                    }
                default:
                    roundEntries.append(ContextLiveActivity.Entry(
                        id: id,
                        kind: .response,
                        title: step.type,
                        detail: step.text ?? ""
                    ))
                }
            }
            return roundEntries
        }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(entries) { entry in
                ContextActivityEntryView(entry: entry)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ContextActivityEntryView: View, Equatable {
    let entry: ContextLiveActivity.Entry

    private var icon: String {
        switch entry.kind {
        case .reasoning: "sparkles"
        case .response: "text.bubble"
        case .toolCall: "wrench.and.screwdriver"
        case .toolResult: entry.isError ? "xmark.circle" : "checkmark.circle"
        }
    }

    private var isToolEntry: Bool {
        entry.kind == .toolCall || entry.kind == .toolResult
    }

    var body: some View {
        if isToolEntry {
            ContextToolActivityView(
                name: entry.toolName ?? entry.title.replacingOccurrences(of: " result", with: ""),
                arguments: entry.payload,
                argumentText: entry.detail,
                resultPayload: entry.resultPayload,
                resultText: entry.resultDetail,
                isResultRunning: entry.isResultRunning,
                isResultError: entry.isError
            )
        } else if entry.kind == .response {
            if !entry.detail.isEmpty {
                ContextMarkdownOutput(markdown: entry.detail)
                    .equatable()
            }
        } else {
            VStack(alignment: .leading, spacing: entry.detail.isEmpty ? 0 : 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.isError ? Color.red.opacity(0.72) : Color.secondary.opacity(0.68))
                        .frame(width: 15, height: 18, alignment: .leading)

                    Text(entry.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.78))
                }

                if !entry.detail.isEmpty {
                    if entry.kind == .reasoning {
                        ContextActivityMarkdown(markdown: entry.detail)
                            .equatable()
                            .padding(.leading, 21)
                    } else {
                        Text(entry.detail)
                            .font(isToolEntry ? .system(size: 12, design: .monospaced) : .system(size: 13))
                            .foregroundStyle(entry.isError ? Color.red.opacity(0.72) : Color.secondary.opacity(0.76))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 21)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ContextActivityMarkdown: View, Equatable {
    let markdown: String

    var body: some View {
        ContextMarkdownDocument(markdown: markdown, baseFontSize: 13, tone: .secondary)
    }
}

private struct ContextShimmerText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> ContextShimmerLabelView {
        let view = ContextShimmerLabelView()
        view.update(text)
        return view
    }

    func updateNSView(_ nsView: ContextShimmerLabelView, context: Context) {
        nsView.update(text)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: ContextShimmerLabelView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// The shimmer runs entirely in Core Animation. SwiftUI only updates this view
/// when the status string changes; it never participates in animation frames.
private final class ContextShimmerLabelView: NSView {
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private let gradient = CAGradientLayer()
    private let textMask = CATextLayer()
    private var value = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(gradient)

        gradient.colors = [
            NSColor.labelColor.withAlphaComponent(0.82).cgColor,
            NSColor.labelColor.withAlphaComponent(0.82).cgColor,
            NSColor.secondaryLabelColor.withAlphaComponent(0.72).cgColor,
            NSColor.white.cgColor,
            NSColor.secondaryLabelColor.withAlphaComponent(0.72).cgColor,
            NSColor.labelColor.withAlphaComponent(0.82).cgColor,
            NSColor.labelColor.withAlphaComponent(0.82).cgColor
        ]
        gradient.locations = [0, 0.28, 0.42, 0.5, 0.58, 0.72, 1]
        gradient.mask = textMask

        textMask.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textMask.alignmentMode = .left
        textMask.truncationMode = .none
        textMask.isWrapped = false
        textMask.font = Self.font
        textMask.fontSize = Self.font.pointSize
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(_ text: String) {
        guard value != text else { return }
        value = text
        textMask.string = NSAttributedString(
            string: text,
            attributes: [
                .font: Self.font,
                .foregroundColor: NSColor.white
            ]
        )
        setAccessibilityLabel(text)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let size = NSAttributedString(
            string: value,
            attributes: [.font: Self.font]
        ).size()
        return NSSize(width: ceil(size.width) + 1, height: ceil(size.height) + 2)
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        textMask.frame = bounds
        startAnimationIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            gradient.removeAnimation(forKey: "curatez-shimmer")
        } else {
            startAnimationIfNeeded()
        }
    }

    private func startAnimationIfNeeded() {
        guard window != nil,
              bounds.width > 0,
              gradient.animation(forKey: "curatez-shimmer") == nil else { return }

        gradient.startPoint = CGPoint(x: 1, y: 0.5)
        gradient.endPoint = CGPoint(x: 2, y: 0.5)
        let group = CAAnimationGroup()
        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = CGPoint(x: -1, y: 0.5)
        start.toValue = CGPoint(x: 1, y: 0.5)
        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = CGPoint(x: 0, y: 0.5)
        end.toValue = CGPoint(x: 2, y: 0.5)
        group.animations = [start, end]
        group.duration = 1.55
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .linear)
        group.isRemovedOnCompletion = false
        gradient.add(group, forKey: "curatez-shimmer")
    }
}

private struct ContextMarkdownOutput: View, Equatable {
    let markdown: String

    var body: some View {
        ContextMarkdownDocument(markdown: markdown, baseFontSize: 13, tone: .primary)
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var displayText: String {
        if case .string(let value) = self { return value }
        if case .object(let object) = self,
           case .array(let content)? = object["content"] {
            let text = content.compactMap { part -> String? in
                guard case .object(let value) = part,
                      case .string(let text)? = value["text"] else { return nil }
                return text
            }.joined(separator: "\n")
            if !text.isEmpty { return text }
        }
        guard let data = try? JSONEncoder.curatez.encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: pretty, encoding: .utf8) else { return "" }
        return value
    }
}

/// Registers a section directly with the enclosing AppKit scroll surface.
/// Unlike a GeometryReader preference, this marker does not publish layout
/// values through the entire SwiftUI document tree on every scroll frame.
private struct ContextItemScrollAnchor: NSViewRepresentable {
    let itemID: UUID
    let cache: ContextEditorScrollCache

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.configure(itemID: itemID, cache: cache)
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.configure(itemID: itemID, cache: cache)
    }

    static func dismantleNSView(_ nsView: AnchorView, coordinator: Void) {
        nsView.detach()
    }

    final class AnchorView: NSView {
        private weak var cache: ContextEditorScrollCache?
        private var itemID: UUID?
        private var hasScheduledScrollResolution = false

        override var isOpaque: Bool { false }

        func configure(itemID: UUID, cache: ContextEditorScrollCache) {
            guard self.itemID != itemID || self.cache !== cache else {
                if cache.resolvedScrollView == nil { resolveScrollView() }
                return
            }
            detach()
            self.itemID = itemID
            self.cache = cache
            cache.register(self, for: itemID)
            resolveScrollView()
        }

        func detach() {
            guard let itemID, let cache else { return }
            cache.unregister(self, for: itemID)
            self.itemID = nil
            self.cache = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let itemID, let cache else { return }
            cache.register(self, for: itemID)
            resolveScrollView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolveScrollView()
        }

        private func resolveScrollView() {
            guard let cache else { return }
            if let scrollView = enclosingScrollView {
                hasScheduledScrollResolution = false
                cache.install(scrollView: scrollView)
                return
            }
            guard window != nil, !hasScheduledScrollResolution else { return }
            hasScheduledScrollResolution = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hasScheduledScrollResolution = false
                if let scrollView = self.enclosingScrollView {
                    self.cache?.install(scrollView: scrollView)
                }
            }
        }
    }
}

private extension Animation {
    /// Exact cubic representation of the quadratic position curve
    /// B(t) = (1-t)^2 * from + 2(1-t)t * control + t^2 * to.
    /// A control value near the destination gives navigation a clear start
    /// and a soft, well-damped arrival.
    static var contextNavigation: Animation {
        let control = 0.82
        return .timingCurve(
            1.0 / 3.0,
            2.0 * control / 3.0,
            2.0 / 3.0,
            (1.0 + 2.0 * control) / 3.0,
            duration: 0.46
        )
    }
}
