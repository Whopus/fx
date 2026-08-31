import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct CaptureDetailView: View {
    private enum DetailSelection: Hashable {
        case defaultTab
        case content
        case file(UUID)
    }

    @ObservedObject var store: CaptureStore
    let recordID: UUID
    let onClose: () -> Void

    @State private var selectedTab: DetailSelection = .defaultTab
    @State private var title = ""
    @State private var tags: [String] = []
    @State private var newTagText = ""
    @State private var isAddingTag = false
    @State private var description = ""
    @State private var itemType: CaptureSpace = .context
    @State private var originalContent = ""
    @State private var subagentTools = ""
    @State private var subagentSkills = ""
    @State private var subagentModel = ""
    @State private var subagentFork = false
    @State private var tabContent = ""
    @State private var isCreatingTab = false
    @State private var newTabTitle = ""
    @State private var newTabKind: CaptureDetailTab.Kind = .markdown
    @State private var tabPendingDeletion: CaptureDetailTab?
    @State private var errorMessage: String?
    @State private var didSaveDefaultFields = false
    @State private var saveFeedbackGeneration = 0
    @State private var contextPreview = ""
    @State private var didCopyContext = false
    @State private var copyFeedbackGeneration = 0
    @State private var isCoverHovered = false
    @FocusState private var isNewTagFocused: Bool

    private var record: CaptureRecord? {
        store.records.first { $0.id == recordID }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let record {
                detailHero(record)
                detailTabs
                Divider()

                switch selectedTab {
                case .defaultTab:
                    contextTab(record)
                case .content:
                    originalContentTab(record)
                case let .file(id):
                    if let tab = record.detailTabs?.first(where: { $0.id == id }) {
                        fileTabEditor(record: record, tab: tab)
                    } else {
                        contextTab(record)
                    }
                }
            } else {
                ContentUnavailableView("收藏不存在", systemImage: "questionmark.folder")
            }
        }
        .frame(minWidth: 864, minHeight: 640)
        .background(Color.white)
        .background(DetailWindowConfigurator())
        .onExitCommand(perform: onClose)
        .onAppear(perform: loadDefaultFields)
        .onChange(of: record) { _, updatedRecord in
            if let updatedRecord { refreshContextPreview(for: updatedRecord) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard selectedTab == .defaultTab, let record else { return }
            refreshContextPreview(for: record)
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .confirmationDialog(
            "删除这个内容 Tab？",
            isPresented: Binding(
                get: { tabPendingDeletion != nil },
                set: { if !$0 { tabPendingDeletion = nil } }
            ),
            presenting: tabPendingDeletion
        ) { tab in
            Button("将 \(tab.fileName) 移到废纸篓", role: .destructive) {
                deleteTab(tab)
            }
            Button("取消", role: .cancel) {}
        } message: { tab in
            Text("对应文件 \(tab.fileName) 会一起移到废纸篓。")
        }
    }

    private var detailTabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        detailTabButton(
                            title: (record?.space ?? .context) == .context ? "Context" : "Overview",
                            icon: "text.document",
                            selection: .defaultTab
                        )
                        if let record, hasOriginalContent(record) {
                            detailTabButton(
                                title: originalContentTabTitle(for: record),
                                icon: contentIcon(for: record),
                                selection: .content
                            )
                        }
                        ForEach(record?.detailTabs ?? []) { tab in
                            detailTabButton(
                                title: tab.title,
                                icon: iconName(for: tab.kind),
                                selection: .file(tab.id)
                            )
                            .contextMenu {
                                Button("删除 Tab", systemImage: "trash", role: .destructive) {
                                    tabPendingDeletion = tab
                                }
                            }
                        }
                        Menu {
                            Button("文本", systemImage: "doc.text") {
                                beginCreatingTab(kind: .plainText)
                            }
                            Button("Markdown", systemImage: "doc.richtext") {
                                beginCreatingTab(kind: .markdown)
                            }
                            Divider()
                            Button("图片…", systemImage: "photo") {
                                importFileTab(kind: .image)
                            }
                            Button("视频…", systemImage: "play.rectangle") {
                                importFileTab(kind: .video)
                            }
                            Button("其他文件…", systemImage: "doc.badge.plus") {
                                importFileTab()
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 28, height: 28)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .help("新建内容 Tab")
                    }
                    .padding(.leading, 16)
                }
                .scrollIndicators(.hidden)
            }

            if isCreatingTab {
                HStack(spacing: 10) {
                    TextField("例如 Notes", text: $newTabTitle)
                        .textFieldStyle(.roundedBorder)
                    Picker("类型", selection: $newTabKind) {
                        ForEach([CaptureDetailTab.Kind.markdown, .plainText]) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Button("创建", action: createTab)
                        .buttonStyle(.borderedProminent)
                        .disabled(newTabTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消") {
                        isCreatingTab = false
                        newTabTitle = ""
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
            }
        }
    }

    private func detailTabButton(
        title: String,
        icon: String,
        selection: DetailSelection
    ) -> some View {
        let isSelected = selectedTab == selection
        return Button {
            selectTab(selection)
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(isSelected ? .black.opacity(0.08) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            TapGesture().onEnded {
                selectTab(selection)
            }
        )
    }

    private func detailHero(_ record: CaptureRecord) -> some View {
        HStack(alignment: .top, spacing: 0) {
            FeatheredDetailCover(
                record: record,
                coverURL: store.coverURL(for: record),
                posterURL: store.coverPreviewURL(for: record),
                textContent: store.originalTextContent(for: record)
            )
            .frame(width: 420, height: 320)
            .clipped()
            .overlay(alignment: .topLeading) {
                if isCoverHovered {
                    coverHoverControl(record)
                        .padding(14)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isCoverHovered = hovering
                }
            }

            VStack(alignment: .leading, spacing: 20) {
                TextField("Untitled", text: $title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 23, weight: .medium))
                    .lineLimit(2...3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, 96)
                    .padding(.top, 15)

                HStack(spacing: 12) {
                    itemTypeMenu
                    tagPills
                }

                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(descriptionFieldLabel)
                    TextEditor(text: $description)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(.leading, -5)
                        .padding(.vertical, 3)
                        .frame(minHeight: 52)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                saveDetailsButton
            }
            .padding(.top, 5)
            .padding(.trailing, 0)
            .padding(.bottom, 16)
            .padding(.leading, 64)
        }
        .frame(minHeight: 320, alignment: .top)
        .background(Color.white)
        .onAppear(perform: clearInitialDefaultFocus)
    }

    private var saveDetailsButton: some View {
        Button(action: saveDefaultFields) {
            Label(
                didSaveDefaultFields ? "已保存" : "保存",
                systemImage: didSaveDefaultFields ? "checkmark.circle.fill" : "tray.and.arrow.down"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(didSaveDefaultFields ? Color.green : Color.primary.opacity(0.82))
            .frame(width: 86, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.18), value: didSaveDefaultFields)
    }

    private var tagPills: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                    HStack(spacing: 5) {
                        Text(tag)
                            .lineLimit(1)
                        Button {
                            tags.remove(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .frame(width: 14, height: 14)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.78))
                    .padding(.leading, 10)
                    .padding(.trailing, 5)
                    .frame(height: 24)
                    .background(.black.opacity(0.055))
                    .clipShape(Capsule())
                }

                if isAddingTag {
                    HStack(spacing: 4) {
                        TextField("Tag", text: $newTagText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 76)
                            .focused($isNewTagFocused)
                            .onSubmit(commitNewTag)
                        Button(action: commitNewTag) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 15, height: 15)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(.black.opacity(0.055))
                    .clipShape(Capsule())
                } else {
                    Button {
                        isAddingTag = true
                        Task { @MainActor in
                            await Task.yield()
                            isNewTagFocused = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .background(.black.opacity(0.055))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("添加 Tag")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 28)
    }

    private var itemTypeMenu: some View {
        Menu {
            ForEach(CaptureSpace.allCases) { space in
                Button {
                    itemType = space
                } label: {
                    if itemType == space {
                        Label(space.displayName, systemImage: "checkmark")
                    } else {
                        Label(space.displayName, systemImage: space.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: itemType.icon)
                Text(itemType.displayName)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(.black.opacity(0.055))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("修改 Item 类型")
    }

    private func commitNewTag() {
        let tag = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty,
           !tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        newTagText = ""
        isAddingTag = false
        isNewTagFocused = false
    }

    private var copyContextButton: some View {
        Button(action: saveAndCopyContext) {
            Image(systemName: didCopyContext ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(didCopyContext ? Color.green : Color.primary.opacity(0.8))
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: didCopyContext)
        .help(didCopyContext ? "Context 已复制" : "复制 Context")
    }

    private func coverHoverControl(_ record: CaptureRecord) -> some View {
        Menu {
            Button("图片封面…", systemImage: "photo") { chooseImageCover() }
            Button("视频封面…", systemImage: "video") { chooseVideoCover() }
            if record.coverFileName != nil {
                Divider()
                Button("移除封面", systemImage: "xmark", role: .destructive) { removeCover() }
            }
        } label: {
            Label("切换封面", systemImage: "photo.badge.arrow.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black.opacity(0.82))
                .frame(width: 86, height: 30)
                .background(.white.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 7, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("设置图片或视频封面")
    }

    private func contextTab(_ record: CaptureRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if itemType == .subagent {
                    subagentConfigurationSection
                    Divider()
                }
                contextPreviewSection
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private func originalContentTab(_ record: CaptureRecord) -> some View {
        if isAgentDefinition(record) {
            editableAgentContent(record)
        } else {
        VStack(spacing: 0) {
            HStack {
                Label(record.fileName ?? record.kind.displayName, systemImage: contentIcon(for: record))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if record.sourceURL != nil || store.fileURL(for: record) != nil {
                    Button(action: { openOriginal(record) }) {
                        compactFileActionLabel("打开", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                }
                Button(action: { revealOriginalInFinder(record) }) {
                    compactFileActionLabel("Finder", systemImage: "folder")
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 27)
            .padding(.trailing, 18)
            .frame(height: 44)
            Divider()

            switch record.kind {
            case .image, .browserSnapshot:
                if let fileURL = store.fileURL(for: record) {
                    DetailFilePreview(url: fileURL, kind: .image)
                } else {
                    unavailableOriginalContent
                }
            case .video:
                if let videoURL = store.fileURL(for: record)
                    ?? record.sourceURL.flatMap(URL.init(string:)) {
                    DetailFilePreview(url: videoURL, kind: .video)
                } else {
                    unavailableOriginalContent
                }
            case .text, .link:
                if let text = store.originalTextContent(for: record) {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 16))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(24)
                    }
                } else if let sourceURL = record.sourceURL {
                    ScrollView {
                        Text(sourceURL)
                            .font(.system(size: 16))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(24)
                    }
                } else {
                    unavailableOriginalContent
                }
            }
        }
        }
    }

    private func editableAgentContent(_ record: CaptureRecord) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(originalContentTabTitle(for: record), systemImage: itemType.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("保存正文") {
                    do {
                        try store.updateOriginalText(for: recordID, text: originalContent)
                        showDefaultSaveFeedback()
                    } catch {
                        showError(error)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18)
            .frame(height: 44)
            Divider()
            TextEditor(text: $originalContent)
                .font(.system(size: 14, design: itemType == .query ? .default : .monospaced))
                .scrollContentBackground(.hidden)
                .padding(16)
        }
    }

    private var subagentConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            fieldLabel("SUBAGENT CONFIGURATION")
            HStack(spacing: 12) {
                detailConfigurationField("TOOLS", text: $subagentTools, prompt: "read, search, shell")
                detailConfigurationField("SKILLS", text: $subagentSkills, prompt: "research, review")
            }
            detailConfigurationField("MODEL", text: $subagentModel, prompt: "provider/model")
            Toggle("Fork parent message context", isOn: $subagentFork)
                .font(.system(size: 12, weight: .medium))
                .toggleStyle(.switch)
        }
    }

    private func detailConfigurationField(
        _ label: String,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(label)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.black.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var descriptionFieldLabel: String {
        switch itemType {
        case .tool: "CAPABILITY DESCRIPTION"
        case .skill: "WHEN TO USE"
        case .subagent: "RESPONSIBILITY"
        default: "DESCRIPTION"
        }
    }

    private func originalContentTabTitle(for record: CaptureRecord) -> String {
        switch record.space ?? .context {
        case .system: "System Prompt"
        case .context: "Content"
        case .query: "Query"
        case .tool: "Definition"
        case .skill: "Instructions"
        case .subagent: "System Prompt"
        case .session: "Notebook"
        }
    }

    private func isAgentDefinition(_ record: CaptureRecord) -> Bool {
        switch record.space ?? .context {
        case .system, .query, .tool, .skill, .subagent: true
        case .context, .session: false
        }
    }

    private var unavailableOriginalContent: some View {
        ContentUnavailableView("内容不可用", systemImage: "doc.questionmark")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileTabEditor(record: CaptureRecord, tab: CaptureDetailTab) -> some View {
        VStack(spacing: 0) {
            HStack {
                Label(tab.fileName, systemImage: iconName(for: tab.kind))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let fileURL = store.fileURL(for: tab, in: record) {
                    Button(action: { NSWorkspace.shared.open(fileURL) }) {
                        compactFileActionLabel("打开", systemImage: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    Button(action: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }) {
                        compactFileActionLabel("Finder", systemImage: "folder")
                    }
                    .buttonStyle(.plain)
                }
                Button("删除", role: .destructive) { tabPendingDeletion = tab }
                if tab.kind.isTextEditable {
                    Button("保存") { saveTabContent(tab) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.leading, 27)
            .padding(.trailing, 18)
            .frame(height: 44)
            Divider()
            if tab.kind.isTextEditable {
                TextEditor(text: $tabContent)
                    .font(.system(size: 14, design: tab.kind == .markdown ? .monospaced : .default))
                    .scrollContentBackground(.hidden)
                    .padding(14)
            } else if let fileURL = store.fileURL(for: tab, in: record) {
                DetailFilePreview(url: fileURL, kind: tab.kind)
            }
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(.secondary)
    }

    private var contextPreviewSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                fieldLabel("CONTEXT PREVIEW")
                Spacer()
                copyContextButton
            }

            Text(contextPreview.isEmpty ? "暂无可复制内容" : contextPreview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(contextPreview.isEmpty ? Color.secondary : Color.primary.opacity(0.78))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .padding(.vertical, 4)
        }
    }

    private func compactFileActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary.opacity(0.82))
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(.black.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.black.opacity(0.055), lineWidth: 0.5)
            }
    }

    private func loadDefaultFields() {
        guard let record else { return }
        title = record.title
        tags = record.tags ?? []
        newTagText = ""
        isAddingTag = false
        description = record.itemDescription ?? ""
        itemType = record.space ?? .context
        originalContent = store.originalTextContent(for: record) ?? ""
        subagentTools = record.agentConfiguration?.tools.joined(separator: ", ") ?? ""
        subagentSkills = record.agentConfiguration?.skills.joined(separator: ", ") ?? ""
        subagentModel = record.agentConfiguration?.model ?? ""
        subagentFork = record.agentConfiguration?.fork ?? false
        refreshContextPreview(for: record)
    }

    private func refreshContextPreview(for record: CaptureRecord) {
        contextPreview = store.context(for: record)
    }

    private func copyCurrentContext() {
        guard !contextPreview.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(contextPreview, forType: .string)
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        withAnimation(.easeOut(duration: 0.16)) { didCopyContext = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard generation == copyFeedbackGeneration else { return }
            withAnimation(.easeOut(duration: 0.16)) { didCopyContext = false }
        }
    }

    private func clearInitialDefaultFocus() {
        Task { @MainActor in
            // SwiftUI assigns the first TextField after the sheet appears.
            // Clear it on the following presentation cycle so Title does not
            // open with all text selected, while remaining clickable/editable.
            try? await Task.sleep(for: .milliseconds(100))
            guard selectedTab == .defaultTab else { return }
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func selectTab(_ selection: DetailSelection) {
        guard selectedTab != selection else { return }
        selectedTab = selection
        guard case let .file(id) = selection,
              let record,
              let tab = record.detailTabs?.first(where: { $0.id == id }) else {
            if selection == .defaultTab { loadDefaultFields() }
            return
        }
        tabContent = store.content(for: tab, in: record)
    }

    private func saveDefaultFields() {
        _ = persistDefaultFields()
    }

    private func saveAndCopyContext() {
        guard persistDefaultFields(), let record else { return }
        refreshContextPreview(for: record)
        copyCurrentContext()
    }

    @discardableResult
    private func persistDefaultFields() -> Bool {
        do {
            try store.updateDetails(
                for: recordID,
                title: title,
                tags: tags,
                description: description
            )
            store.update(recordID) { $0.space = itemType }
            store.update(recordID) { record in
                if itemType == .subagent {
                    let model = subagentModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    record.agentConfiguration = CaptureAgentConfiguration(
                        tools: commaSeparatedValues(subagentTools),
                        skills: commaSeparatedValues(subagentSkills),
                        model: model.isEmpty ? nil : model,
                        fork: subagentFork
                    )
                } else {
                    record.agentConfiguration = nil
                }
            }
            showDefaultSaveFeedback()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func commaSeparatedValues(_ source: String) -> [String] {
        source.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func showDefaultSaveFeedback() {
        saveFeedbackGeneration += 1
        let generation = saveFeedbackGeneration
        withAnimation(.easeOut(duration: 0.18)) {
            didSaveDefaultFields = true
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard generation == saveFeedbackGeneration else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                didSaveDefaultFields = false
            }
        }
    }

    private func createTab() {
        do {
            let tab = try store.addDetailTab(for: recordID, title: newTabTitle, kind: newTabKind)
            isCreatingTab = false
            newTabTitle = ""
            selectTab(.file(tab.id))
        } catch {
            showError(error)
        }
    }

    private func beginCreatingTab(kind: CaptureDetailTab.Kind) {
        newTabKind = kind
        newTabTitle = ""
        isCreatingTab = true
    }

    private func importFileTab(kind: CaptureDetailTab.Kind? = nil) {
        let panel = NSOpenPanel()
        panel.title = switch kind {
        case .image: "选择图片内容"
        case .video: "选择视频内容"
        default: "导入内容文件"
        }
        panel.message = "文件会复制到当前收藏的子文件夹，并成为一个新的详情 Tab。"
        panel.prompt = "导入"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch kind {
        case .image: panel.allowedContentTypes = [.image]
        case .video: panel.allowedContentTypes = [.movie]
        default: break
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let tab = try await store.importDetailTabFile(for: recordID, from: url)
                selectTab(.file(tab.id))
            } catch {
                showError(error)
            }
        }
    }

    private func saveTabContent(_ tab: CaptureDetailTab) {
        do {
            try store.saveContent(tabContent, for: tab.id, in: recordID)
            if let record { refreshContextPreview(for: record) }
        } catch {
            showError(error)
        }
    }

    private func deleteTab(_ tab: CaptureDetailTab) {
        tabPendingDeletion = nil
        do {
            try store.deleteDetailTab(tab.id, from: recordID)
            selectedTab = .defaultTab
            loadDefaultFields()
        } catch {
            showError(error)
        }
    }

    private func chooseImageCover() {
        let panel = NSOpenPanel()
        panel.title = "选择图片封面"
        panel.prompt = "设置封面"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await store.replaceCover(for: recordID, from: url)
            } catch {
                showError(error)
            }
        }
    }

    private func chooseVideoCover() {
        let panel = NSOpenPanel()
        panel.title = "选择视频封面"
        panel.prompt = "设置封面"
        panel.allowedContentTypes = [.movie]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await store.replaceCoverVideo(for: recordID, from: url)
            } catch {
                showError(error)
            }
        }
    }

    private func removeCover() {
        do {
            try store.removeCover(for: recordID)
        } catch {
            showError(error)
        }
    }

    private func openOriginal(_ record: CaptureRecord) {
        if let source = record.sourceURL, let url = URL(string: source) {
            NSWorkspace.shared.open(url)
        } else if let fileURL = store.fileURL(for: record) {
            NSWorkspace.shared.open(fileURL)
        }
    }

    private func revealOriginalInFinder(_ record: CaptureRecord) {
        if let fileURL = store.fileURL(for: record) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else if let folderURL = store.containerURL(for: record) {
            NSWorkspace.shared.activateFileViewerSelecting([folderURL])
        }
    }

    private func showError(_ error: Error) {
        let message = error.localizedDescription
        errorMessage = message
    }

    private func iconName(for kind: CaptureDetailTab.Kind) -> String {
        switch kind {
        case .markdown: "doc.richtext"
        case .plainText: "doc.text"
        case .image: "photo"
        case .video: "play.rectangle"
        case .file: "doc"
        }
    }

    private func hasOriginalContent(_ record: CaptureRecord) -> Bool {
        if store.originalTextContent(for: record) != nil { return true }
        if let sourceURL = record.sourceURL, !sourceURL.isEmpty { return true }
        return store.fileURL(for: record) != nil
    }

    private func contentIcon(for record: CaptureRecord) -> String {
        switch record.kind {
        case .text: "doc.text"
        case .link: "link"
        case .video: "play.rectangle"
        case .image, .browserSnapshot: "photo"
        }
    }
}

private struct DetailWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DetailWindowConfigurationView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DetailWindowConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    private func configureWindow() {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear

        for view in [window.contentView, window.contentView?.superview].compactMap({ $0 }) {
            view.wantsLayer = true
            view.layer?.cornerRadius = 4
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
        }
    }
}

private struct FeatheredDetailCover: View {
    let record: CaptureRecord
    let coverURL: URL?
    let posterURL: URL?
    let textContent: String?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.white

                if record.coverKind == nil {
                    coverPreview(size: geometry.size)
                } else {
                    coverPreview(size: geometry.size)
                        .mask {
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: 0.55),
                                    .init(color: .white.opacity(0.94), location: 0.694),
                                    .init(color: .white.opacity(0.78), location: 0.811),
                                    .init(color: .white.opacity(0.42), location: 0.919),
                                    .init(color: .clear, location: 1)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                        .mask {
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .white, location: 0),
                                    .init(color: .white, location: 0.3),
                                    .init(color: .white.opacity(0.94), location: 0.524),
                                    .init(color: .white.opacity(0.78), location: 0.706),
                                    .init(color: .white.opacity(0.42), location: 0.874),
                                    .init(color: .clear, location: 1)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private func coverPreview(size: CGSize) -> some View {
        DetailCoverPreview(
            record: record,
            coverURL: coverURL,
            posterURL: posterURL,
            textContent: textContent
        )
        .frame(width: size.width, height: size.height)
        .clipped()
    }
}

private struct DetailCoverPreview: View {
    let record: CaptureRecord
    let coverURL: URL?
    let posterURL: URL?
    let textContent: String?

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            switch record.coverKind {
            case .image:
                if let coverURL {
                    CachedLocalImage(
                        url: coverURL,
                        maxPixelSize: 2_000,
                        contentMode: .fill,
                        showsProgress: true
                    )
                } else {
                    textCover
                }
            case .video:
                if let player {
                    VideoPlayer(player: player)
                } else if let posterURL {
                    CachedLocalImage(
                        url: posterURL,
                        maxPixelSize: 2_000,
                        contentMode: .fill,
                        showsProgress: true
                    )
                } else {
                    textCover
                }
            case nil:
                textCover
            }
        }
        .clipped()
        .onAppear(perform: preparePlayer)
        .onChange(of: record.coverFileName) { _, _ in preparePlayer() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var textCover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: fallbackIcon)
                .font(.system(size: 17, weight: .medium))
            Text(record.title)
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .lineLimit(3)
                .minimumScaleFactor(0.72)
            if let summary = fallbackSummary {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer()
            HStack {
                Text(record.tags?.map { "#\($0)" }.joined(separator: " ") ?? "")
                    .lineLimit(1)
                Spacer()
                Text(record.createdAt, style: .date)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .foregroundStyle(.black.opacity(0.86))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.94, green: 0.93, blue: 0.89))
    }

    private var fallbackSummary: String? {
        if let description = record.itemDescription, !description.isEmpty {
            return description
        }
        guard let textContent else { return nil }
        let text = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != record.title else { return nil }
        return text
    }

    private var fallbackIcon: String {
        switch record.kind {
        case .text: "text.quote"
        case .link: "link"
        case .video: "play.rectangle"
        case .image, .browserSnapshot: "photo"
        }
    }

    private func preparePlayer() {
        player?.pause()
        player = nil
        guard record.coverKind == .video, let coverURL else { return }
        player = AVPlayer(url: coverURL)
    }
}

private struct DetailFilePreview: View {
    let url: URL
    let kind: CaptureDetailTab.Kind

    @State private var player: AVPlayer?

    var body: some View {
        Group {
            switch kind {
            case .image:
                CachedLocalImage(
                    url: url,
                    maxPixelSize: 2_400,
                    contentMode: .fit,
                    showsProgress: true
                )
                .padding(18)
            case .video:
                if let player {
                    VideoPlayer(player: player)
                        .padding(18)
                } else {
                    placeholder(icon: "play.rectangle", label: url.lastPathComponent)
                }
            case .file:
                placeholder(icon: "doc", label: url.lastPathComponent)
            case .markdown, .plainText:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.025))
        .onAppear {
            if kind == .video { player = AVPlayer(url: url) }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func placeholder(icon: String, label: String) -> some View {
        VStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Button("用系统应用打开") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
