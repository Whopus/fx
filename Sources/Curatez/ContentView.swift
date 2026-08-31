import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AddContentType: String, CaseIterable, Identifiable {
    case text = "文本"
    case image = "图片"
    case video = "视频"

    var id: Self { self }

    var icon: String {
        switch self {
        case .text: "doc.text"
        case .image: "photo"
        case .video: "play.rectangle"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var captureStore: CaptureStore

    @State private var gallerySpace: CaptureSpace = .context
    @State private var isItemTypePickerPresented = false
    @State private var columnCount = 4.0
    @State private var isAddPresented = false
    @State private var isEditPresented = false
    @State private var editorSessionID: UUID?
    @State private var addContentType: AddContentType = .text
    @State private var newText = ""
    @State private var pendingImage: NSImage?
    @State private var pendingImageTitle = "粘贴的图片"
    @State private var pendingVideoURL: URL?
    @State private var isSavingContent = false
    @State private var newItemTitle = ""
    @State private var newContextTags = ""
    @State private var newItemDescription = ""
    @State private var newItemBody = ""
    @State private var newSubagentTools = ""
    @State private var newSubagentSkills = ""
    @State private var newSubagentModel = ""
    @State private var newSubagentFork = false
    @State private var operationError: String?
    @State private var collectionToRename: CollectionFolder?
    @State private var collectionToDelete: CollectionFolder?
    @State private var renamedCollectionName = ""
    @State private var detailRecordID: UUID?

    private var visibleItems: [GalleryItem] {
        let visibleRecords = captureStore.records.filter {
            !$0.isTrashed && ($0.space ?? .context) == gallerySpace
        }
        return visibleRecords.map {
            let media = captureStore.galleryMediaURLs(for: $0)
            return GalleryItem(
                capture: $0,
                coverPreviewURL: media.preview,
                coverVideoURL: media.video
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.white
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                gallery
            }
            .ignoresSafeArea(.container, edges: .top)
            .padding(.top, 12)

            HStack(spacing: 10) {
                Button {
                    editorSessionID = nil
                    withAnimation(.easeOut(duration: 0.2)) {
                        isEditPresented = true
                    }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.black.opacity(0.04)))
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(captureStore.selectedCollection == nil)
                .help("编辑当前文件夹")

                Button {
                    isAddPresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(.white)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.black.opacity(0.04)))
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(captureStore.selectedCollection == nil)
            }
            .padding(10)

            if isEditPresented {
                CollectionEditorView(store: captureStore, initialSessionID: editorSessionID) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isEditPresented = false
                    }
                    editorSessionID = nil
                }
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .sheet(isPresented: $isAddPresented) {
            addSheet
        }
        .sheet(item: $collectionToRename) { collection in
            renameCollectionSheet(collection)
        }
        .sheet(isPresented: Binding(
            get: { detailRecordID != nil },
            set: { if !$0 { detailRecordID = nil } }
        )) {
            if let id = detailRecordID {
                CaptureDetailView(
                    store: captureStore,
                    recordID: id,
                    onClose: { detailRecordID = nil }
                )
            }
        }
        .overlay(alignment: .top) {
            CaptureStatusOverlay()
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(operationError ?? "未知错误")
        }
        .confirmationDialog(
            "删除标签和文件夹？",
            isPresented: Binding(
                get: { collectionToDelete != nil },
                set: { if !$0 { collectionToDelete = nil } }
            ),
            presenting: collectionToDelete
        ) { collection in
            Button("移到废纸篓", role: .destructive) {
                deleteCollection(collection)
            }
            Button("取消", role: .cancel) {}
        } message: { collection in
            Text("“\(collection.name)”及其中的所有收藏都会移到废纸篓。\n\(collection.path)")
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 24) {
                    ForEach(captureStore.collections) { collection in
                        collectionTab(collection)
                    }

                    Button {
                        chooseCollectionFolder()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.05))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("添加文件夹标签")
                }
            }
            .scrollIndicators(.hidden)
            .layoutPriority(1)

            Spacer(minLength: 24)

            CaptureModeControl()
            .padding(.trailing, 24)

            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                Slider(value: $columnCount, in: 3...5, step: 1)
                    .tint(.black)
                    .frame(width: 100)
                Image(systemName: "square")
            }
            .font(.system(size: 16, weight: .light))
            .foregroundStyle(.secondary.opacity(0.7))

            Button {
                isItemTypePickerPresented.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: gallerySpace.icon)
                        .foregroundStyle(.secondary)
                    Text(gallerySpace.displayName)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.black)
                .padding(.horizontal, 15)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isItemTypePickerPresented, arrowEdge: .bottom) {
                itemTypePicker
            }
            .padding(.leading, 8)
            .offset(x: 12)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.black.opacity(0.08)).frame(height: 1)
        }
    }

    private var itemTypePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Item Types")
                    .font(.system(size: 14, weight: .semibold))
                Text("选择一种类型进行查看和管理")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ForEach(CaptureSpace.allCases) { space in
                itemTypeRow(space)
            }
        }
        .padding(.bottom, 10)
        .frame(width: 284)
        .background(Color.white)
    }

    private func itemTypeRow(_ space: CaptureSpace) -> some View {
        let isSelected = gallerySpace == space
        let count = captureStore.records.filter {
            !$0.isTrashed && ($0.space ?? .context) == space
        }.count
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                gallerySpace = space
            }
            isItemTypePickerPresented = false
        } label: {
            HStack(spacing: 11) {
                Image(systemName: space.icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .white : .primary.opacity(0.78))
                    .frame(width: 30, height: 30)
                    .background(isSelected ? Color.black : Color.black.opacity(0.055))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(space.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(space.summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .frame(minHeight: 20)
                    .background(.black.opacity(0.045))
                    .clipShape(Capsule())

                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(isSelected ? 1 : 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 48)
            .background(isSelected ? .black.opacity(0.045) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
    }

    private func collectionTab(_ collection: CollectionFolder) -> some View {
        let isSelected = captureStore.selectedCollectionID == collection.id
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                captureStore.selectCollection(collection.id)
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isSelected ? "folder.fill" : "folder")
                    .font(.system(size: 15, weight: .medium))
                Text(collection.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .black : .secondary.opacity(0.68))
            .frame(height: 52)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? .black : .clear)
                    .frame(height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("在 Finder 中显示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([captureStore.folderURL(for: collection)])
            }
            Button("重命名文件夹", systemImage: "pencil") {
                renamedCollectionName = collection.name
                collectionToRename = collection
            }
            Button("设置默认工作目录…", systemImage: "terminal") {
                chooseWorkingDirectory(for: collection)
            }
            if collection.workingDirectoryPath != nil {
                Button("使用 Library 文件夹作为工作目录", systemImage: "arrow.uturn.backward") {
                    do {
                        try captureStore.setWorkingDirectory(nil, for: collection.id)
                    } catch {
                        operationError = error.localizedDescription
                    }
                }
            }
            Divider()
            Button("删除标签和文件夹", systemImage: "trash", role: .destructive) {
                collectionToDelete = collection
            }
        }
        .help("Library: \(collection.path)\nCWD: \(captureStore.workingDirectoryURL(for: collection).path)")
    }

    @ViewBuilder
    private var gallery: some View {
        let items = visibleItems
        let layoutSignature = galleryLayoutSignature(for: items)
        if items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: captureStore.selectedCollection == nil ? "folder.badge.plus" : "folder")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, height: 58)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
                Text(captureStore.selectedCollection == nil
                    ? "添加一个文件夹标签"
                    : "还没有 \(gallerySpace.displayName) Item")
                    .font(.system(size: 17, weight: .semibold))
                Text(captureStore.selectedCollection == nil
                    ? "点击顶部的 +，选择一个用于保存收藏的文件夹。"
                    : "点击右下角的 +，新内容会自动归入 \(gallerySpace.displayName)。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                let galleryMargin: CGFloat = 6
                let availableWidth = max(1, geometry.size.width - galleryMargin * 2)
                let cardSpacing: CGFloat = 6
                let responsiveColumns = max(1, Int((availableWidth + cardSpacing) / 284))
                let effectiveColumns = min(Int(columnCount), responsiveColumns)

                ScrollView {
                    MasonryLayout(
                        columns: effectiveColumns,
                        spacing: cardSpacing,
                        layoutSignature: layoutSignature
                    ) {
                        ForEach(items) { item in
                            GalleryCard(
                                item: item,
                                isSuspended: isEditPresented,
                                onToggleSaved: {
                                    captureStore.update(item.id) { $0.isSaved.toggle() }
                                },
                                onTrash: { deleteRecord(item.id) },
                                onRestore: {
                                    captureStore.update(item.id) { $0.isTrashed = false }
                                },
                                onOpenSource: { openSource(for: item) },
                                onOpenDetails: { openItem(item) },
                                onReplaceCover: { chooseCover(for: item.id) },
                                onCopyContext: { copyContext(for: item.id) }
                            )
                            .equatable()
                        }
                    }
                    .padding(.horizontal, galleryMargin)
                    .padding(.top, galleryMargin)
                    .padding(.bottom, 12)
                    .animation(.easeInOut(duration: 0.22), value: items)
                    .animation(.easeInOut(duration: 0.22), value: effectiveColumns)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func galleryLayoutSignature(for items: [GalleryItem]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.aspectRatio)
        }
        return hasher.finalize()
    }

    @ViewBuilder
    private var addSheet: some View {
        switch gallerySpace {
        case .context:
            contextAddSheet
        case .session:
            newSessionSheet
        case .system, .query, .tool, .skill, .subagent:
            typedItemSheet
        }
    }

    private var contextAddSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 24) {
                ForEach(AddContentType.allCases) { type in
                    addContentTypeButton(type)
                }
                Spacer()
                addContentSaveButton
            }
            .padding(.leading, 18)
            .padding(.trailing, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.black.opacity(0.08))
                    .frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 18) {
                contextMetadataPanel

                Group {
                    switch addContentType {
                    case .text:
                        addTextPanel
                    case .image:
                        addImagePanel
                    case .video:
                        addVideoPanel
                    }
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 26)
            .padding(.horizontal, 18)
        }
        .frame(width: 560)
        .background(Color.white)
        .onDisappear(perform: resetAddContent)
    }

    private var contextMetadataPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                typedTextField(
                    label: "TITLE",
                    prompt: "未填写时自动生成",
                    text: $newItemTitle
                )
                typedTextField(
                    label: "TAGS",
                    prompt: "research, reference",
                    text: $newContextTags
                )
            }
            typedTextField(
                label: "DESCRIPTION",
                prompt: "简单描述这个 Context 的内容和用途",
                text: $newItemDescription
            )
        }
    }

    private var typedItemSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: gallerySpace.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New \(gallerySpace.displayName)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(gallerySpace.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: saveTypedItemContent) {
                    Label("保存", systemImage: "tray.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 72, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(isTypedItemSaveDisabled)
                .opacity(isTypedItemSaveDisabled ? 0.3 : 1)
            }
            .padding(.horizontal, 18)
            .frame(height: 58)
            .overlay(alignment: .bottom) {
                Rectangle().fill(.black.opacity(0.08)).frame(height: 1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if gallerySpace != .query {
                        typedTextField(
                            label: gallerySpace == .system ? "TITLE (OPTIONAL)" : "NAME",
                            prompt: typedTitlePrompt,
                            text: $newItemTitle
                        )
                    }

                    if [.tool, .skill, .subagent].contains(gallerySpace) {
                        typedTextField(
                            label: "DESCRIPTION",
                            prompt: typedDescriptionPrompt,
                            text: $newItemDescription
                        )
                    }

                    if gallerySpace != .tool {
                        typedTextEditor(
                            label: typedBodyLabel,
                            prompt: typedBodyPrompt,
                            text: $newItemBody,
                            height: gallerySpace == .subagent ? 150 : 190
                        )
                    }

                    if gallerySpace == .subagent {
                        HStack(spacing: 12) {
                            typedTextField(label: "TOOLS", prompt: "read, search, shell", text: $newSubagentTools)
                            typedTextField(label: "SKILLS", prompt: "research, review", text: $newSubagentSkills)
                        }
                        typedTextField(
                            label: "MODEL (OPTIONAL)",
                            prompt: "provider/model",
                            text: $newSubagentModel
                        )
                        Toggle("Fork parent message context", isOn: $newSubagentFork)
                            .font(.system(size: 12, weight: .medium))
                            .toggleStyle(.switch)
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 580, height: gallerySpace == .subagent ? 620 : 500)
        .background(Color.white)
        .onDisappear(perform: resetAddContent)
    }

    private var newSessionSheet: some View {
        VStack(spacing: 18) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 60, height: 60)
                .background(.black.opacity(0.045))
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            Text("新建 Session")
                .font(.system(size: 19, weight: .semibold))
            Text("Session 由完整的 System、Context、Query、Tool、Skill 和 Subagent notebook 组成。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("打开新编辑会话") {
                isAddPresented = false
                Task { @MainActor in
                    await Task.yield()
                    isEditPresented = true
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(36)
        .frame(width: 460, height: 320)
        .background(Color.white)
    }

    private func typedTextField(
        label: String,
        prompt: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            addFieldLabel(label)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(.black.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.black.opacity(0.06), lineWidth: 0.5)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func typedTextEditor(
        label: String,
        prompt: String,
        text: Binding<String>,
        height: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            addFieldLabel(label)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                }
                TextEditor(text: text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(7)
            }
            .frame(height: height)
            .background(.black.opacity(0.025))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.black.opacity(0.06), lineWidth: 0.5)
            }
        }
    }

    private var typedTitlePrompt: String {
        return switch gallerySpace {
        case .system: "System Instructions"
        case .tool: "echo"
        case .skill: "research"
        case .subagent: "scout"
        default: gallerySpace.displayName
        }
    }

    private var typedDescriptionPrompt: String {
        switch gallerySpace {
        case .tool: "What this tool can do"
        case .skill: "When the agent should use this skill"
        case .subagent: "What this subagent handles"
        default: "Description"
        }
    }

    private var typedBodyLabel: String {
        switch gallerySpace {
        case .system: "SYSTEM CONTENT"
        case .query: "QUERY CONTENT"
        case .skill: "INSTRUCTIONS"
        case .subagent: "SYSTEM PROMPT"
        default: "CONTENT"
        }
    }

    private var typedBodyPrompt: String {
        switch gallerySpace {
        case .system: "Define the agent's behavior and constraints…"
        case .query: "Ask the agent to complete a task…"
        case .skill: "Write the complete reusable skill instructions…"
        case .subagent: "Write this subagent's system instructions…"
        default: "Write content…"
        }
    }

    private var isTypedItemSaveDisabled: Bool {
        let name = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = newItemDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = newItemBody.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch gallerySpace {
        case .system, .query: body.isEmpty
        case .tool: name.isEmpty || detail.isEmpty
        case .skill, .subagent: name.isEmpty || detail.isEmpty || body.isEmpty
        case .context, .session: true
        }
    }

    private func saveTypedItemContent() {
        let model = newSubagentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = gallerySpace == .subagent
            ? CaptureAgentConfiguration(
                tools: commaSeparatedValues(newSubagentTools),
                skills: commaSeparatedValues(newSubagentSkills),
                model: model.isEmpty ? nil : model,
                fork: newSubagentFork
            )
            : nil
        do {
            try captureStore.saveAgentItem(
                space: gallerySpace,
                title: newItemTitle,
                detail: newItemDescription,
                body: newItemBody,
                configuration: configuration
            )
            isAddPresented = false
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func commaSeparatedValues(_ source: String) -> [String] {
        source.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func addContentTypeButton(_ type: AddContentType) -> some View {
        let isSelected = addContentType == type
        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                addContentType = type
            }
        } label: {
            Label(type.rawValue, systemImage: type.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? .black : .secondary.opacity(0.68))
                .frame(height: 48)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? .black : .clear)
                        .frame(height: 3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addTextPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            addFieldLabel("CONTENT")
            ZStack(alignment: .topLeading) {
                if newText.isEmpty {
                    Text("在这里输入或粘贴文本…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary.opacity(0.65))
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $newText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 8)
                    .padding(.horizontal, -5)
                    .frame(height: 170)
            }
        }
    }

    private var addImagePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            addFieldLabel("图片内容")
            addMediaPreview(
                icon: "photo",
                title: pendingImage == nil ? "粘贴一张图片" : pendingImageTitle,
                subtitle: pendingImage == nil ? "按 ⌘V 读取剪贴板中的图片" : "图片已就绪，可以保存到收藏",
                image: pendingImage
            )

            HStack(spacing: 10) {
                pasteButton
                localFileButton(title: "选择本地图片", icon: "photo.badge.plus", action: chooseImage)
            }

        }
    }

    private var addVideoPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            addFieldLabel("视频内容")
            addMediaPreview(
                icon: "play.rectangle",
                title: pendingVideoURL?.lastPathComponent ?? "粘贴视频或视频链接",
                subtitle: pendingVideoURL == nil
                    ? "按 ⌘V 读取本地视频或可播放的视频链接"
                    : (pendingVideoURL?.isFileURL == true ? "本地视频已就绪" : "视频链接已就绪"),
                image: nil
            )

            HStack(spacing: 10) {
                pasteButton
                localFileButton(title: "选择本地视频", icon: "video.badge.plus", action: chooseVideo)
            }

        }
    }

    private var addContentSaveButton: some View {
        Button(action: saveSelectedAddContent) {
            Label(
                isSavingContent ? "导入中" : "保存",
                systemImage: isSavingContent ? "hourglass" : "tray.and.arrow.down"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.82))
            .frame(width: 72, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAddContentSaveDisabled)
        .opacity(isAddContentSaveDisabled ? 0.3 : 1)
    }

    private var isAddContentSaveDisabled: Bool {
        switch addContentType {
        case .text:
            newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image:
            pendingImage == nil
        case .video:
            pendingVideoURL == nil || isSavingContent
        }
    }

    private func saveSelectedAddContent() {
        switch addContentType {
        case .text:
            saveTextContent()
        case .image:
            saveImageContent()
        case .video:
            saveVideoContent()
        }
    }

    private func addFieldLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.65)
    }

    private func addMediaPreview(
        icon: String,
        title: String,
        subtitle: String,
        image: NSImage?
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.025))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                VStack(spacing: 11) {
                    Image(systemName: icon)
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 30)
            }
        }
        .frame(height: 190)
        .overlay(alignment: .bottom) {
            if image != nil {
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThickMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        }
    }

    private var pasteButton: some View {
        Button(action: pasteAddContent) {
            Label("粘贴", systemImage: "doc.on.clipboard")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(.black.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("v", modifiers: .command)
    }

    private func localFileButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(.black.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func renameCollectionSheet(_ collection: CollectionFolder) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("重命名文件夹")
                .font(.system(size: 21, weight: .semibold))
            Text("标签名称和磁盘上的文件夹名称会一起修改。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            TextField("文件夹名称", text: $renamedCollectionName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { collectionToRename = nil }
                Button("重命名") {
                    do {
                        try captureStore.renameCollection(collection.id, to: renamedCollectionName)
                        collectionToRename = nil
                    } catch {
                        collectionToRename = nil
                        operationError = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(renamedCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }

    private func openSource(for item: GalleryItem) {
        if let source = item.sourceURL, let url = URL(string: source) {
            NSWorkspace.shared.open(url)
        } else if let url = item.videoURL, url.isFileURL {
            NSWorkspace.shared.open(url)
        } else if let url = item.imageURL, !url.isFileURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func openItem(_ item: GalleryItem) {
        if captureStore.records.first(where: { $0.id == item.id })?.space == .session {
            editorSessionID = item.id
            withAnimation(.easeOut(duration: 0.2)) {
                isEditPresented = true
            }
        } else {
            detailRecordID = item.id
        }
    }

    private func copyContext(for id: UUID) {
        guard let record = captureStore.records.first(where: { $0.id == id }) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(captureStore.context(for: record), forType: .string)
    }

    private func pasteAddContent() {
        let pasteboard = NSPasteboard.general
        switch addContentType {
        case .text:
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
                operationError = "剪贴板中没有可粘贴的文本。"
                return
            }
            newText = text

        case .image:
            if let fileURL = pasteboardFileURL(conformingTo: .image),
               let image = NSImage(contentsOf: fileURL) {
                pendingImage = image
                pendingImageTitle = fileURL.deletingPathExtension().lastPathComponent
            } else if let image = NSImage(pasteboard: pasteboard) {
                pendingImage = image
                pendingImageTitle = "粘贴的图片"
            } else {
                operationError = "剪贴板中没有可粘贴的图片。"
            }

        case .video:
            if let fileURL = pasteboardFileURL(conformingTo: .movie) {
                pendingVideoURL = fileURL
                return
            }
            let text = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, let url = URL(string: text), VideoSupport.isPlayableRemoteURL(url) else {
                operationError = "剪贴板中没有本地视频或可直接播放的视频链接。"
                return
            }
            pendingVideoURL = url
        }
    }

    private func pasteboardFileURL(conformingTo contentType: UTType) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) ?? []
        return objects
            .compactMap { ($0 as? NSURL)?.absoluteURL }
            .first { url in
                guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
                return type.conforms(to: contentType)
            }
    }

    private func saveTextContent() {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let record = try captureStore.saveText(text)
            try applyNewContextMetadata(to: record)
            isAddPresented = false
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func saveImageContent() {
        guard let pendingImage else { return }
        do {
            let record = try captureStore.saveImage(pendingImage, title: pendingImageTitle)
            try applyNewContextMetadata(to: record)
            isAddPresented = false
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func saveVideoContent() {
        guard let pendingVideoURL else { return }
        if pendingVideoURL.isFileURL {
            isSavingContent = true
            Task { @MainActor in
                do {
                    let record = try await captureStore.importVideo(from: pendingVideoURL)
                    try applyNewContextMetadata(to: record)
                    isSavingContent = false
                    isAddPresented = false
                } catch {
                    isSavingContent = false
                    operationError = error.localizedDescription
                }
            }
        } else {
            do {
                let record = try captureStore.saveVideoURL(pendingVideoURL)
                try applyNewContextMetadata(to: record)
                isAddPresented = false
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func applyNewContextMetadata(to record: CaptureRecord) throws {
        let proposedTitle = newItemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        try captureStore.updateDetails(
            for: record.id,
            title: proposedTitle.isEmpty ? record.title : proposedTitle,
            tags: parsedContextTags,
            description: newItemDescription
        )
        captureStore.update(record.id) { $0.space = .context }
    }

    private var parsedContextTags: [String] {
        let separators = CharacterSet(charactersIn: ",，;；\n")
        var seen = Set<String>()
        return newContextTags
            .components(separatedBy: separators)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            }
            .filter { tag in
                guard !tag.isEmpty else { return false }
                return seen.insert(tag.lowercased()).inserted
            }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "选择要收藏的图片"
        panel.prompt = "选择图片"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            operationError = "无法读取所选图片。"
            return
        }
        pendingImage = image
        pendingImageTitle = url.deletingPathExtension().lastPathComponent
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "选择要收藏的视频"
        panel.prompt = "选择视频"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingVideoURL = url
    }

    private func resetAddContent() {
        addContentType = .text
        newText = ""
        pendingImage = nil
        pendingImageTitle = "粘贴的图片"
        pendingVideoURL = nil
        isSavingContent = false
        newItemTitle = ""
        newContextTags = ""
        newItemDescription = ""
        newItemBody = ""
        newSubagentTools = ""
        newSubagentSkills = ""
        newSubagentModel = ""
        newSubagentFork = false
    }

    private func chooseCollectionFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择收藏文件夹"
        panel.message = "这个文件夹会成为一个标签，之后的收藏会保存为其中的子文件夹。"
        panel.prompt = "添加标签"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try captureStore.addCollection(at: url)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func chooseWorkingDirectory(for collection: CollectionFolder) {
        let panel = NSOpenPanel()
        panel.title = "设置默认工作目录"
        panel.message = "Agent 与 Tool 将在这里运行；Session 和 messages 仍保存在 Library 中。"
        panel.prompt = "设为 CWD"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = captureStore.workingDirectoryURL(for: collection)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try captureStore.setWorkingDirectory(url, for: collection.id)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteCollection(_ collection: CollectionFolder) {
        collectionToDelete = nil
        do {
            try captureStore.deleteCollection(collection.id)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteRecord(_ id: UUID) {
        do {
            try captureStore.deleteRecord(id)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func chooseCover(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "选择封面图片"
        panel.prompt = "设为封面"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                try await captureStore.replaceCover(for: id, from: url)
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

}

extension CaptureRecord.Kind {
    var displayName: String {
        switch self {
        case .text: "文本"
        case .link: "链接"
        case .video: "视频"
        case .image: "图片"
        case .browserSnapshot: "网页快照"
        }
    }
}

private struct CaptureModeControl: View {
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator

    var body: some View {
        HStack(spacing: 8) {
            Button {
                captureCoordinator.toggleCaptureMode()
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(
                            captureCoordinator.isCaptureModeEnabled
                                ? Color.green
                                : Color.secondary.opacity(0.45)
                        )
                        .frame(width: 7, height: 7)
                    Image(systemName: "scope")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(captureCoordinator.isCaptureModeEnabled ? .white : .black)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(captureCoordinator.isCaptureModeEnabled ? .black : .gray.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("开关采集模式 · ⌘D")
        }
    }
}

private struct CaptureStatusOverlay: View {
    @EnvironmentObject private var captureCoordinator: CaptureCoordinator

    var body: some View {
        Group {
            if let message = captureCoordinator.statusMessage {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .frame(height: 34)
                    .background(.black.opacity(0.88))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
                    .padding(.top, 84)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: captureCoordinator.statusMessage)
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
