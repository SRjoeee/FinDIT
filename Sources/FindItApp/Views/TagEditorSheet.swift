import SwiftUI
import GRDB
import FindItCore

/// 标签编辑 Sheet
///
/// 显示当前 clip 的用户标签，支持添加/删除。
/// 操作链：写入文件夹级库 → 增量 sync 到全局库 → 通知刷新搜索。
struct TagEditorSheet: View {
    let sourceFolder: String
    let sourceClipId: Int64
    let globalDB: DatabasePool?

    @Environment(\.dismiss) private var dismiss

    @State private var currentTags: [String] = []
    @State private var newTagText: String = ""
    @State private var popularTags: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("管理标签")
                .font(.headline)

            // 当前标签
            if currentTags.isEmpty {
                Text("暂无用户标签")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(currentTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.subheadline)
                            Button {
                                removeTag(tag)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.fill.tertiary, in: Capsule())
                    }
                }
            }

            Divider()

            // 新标签输入
            HStack {
                TextField("输入标签（逗号或回车分隔）", text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addNewTags() }

                Button("添加") { addNewTags() }
                    .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // 热门标签推荐
            if !popularTags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("热门标签")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(availableSuggestions, id: \.self) { tag in
                            Button(tag) {
                                addTag(tag)
                            }
                            .buttonStyle(.plain)
                            .font(.subheadline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.fill.quaternary, in: Capsule())
                        }
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Spacer()

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400, height: 320)
        .task { loadTags() }
    }

    /// 从热门标签中排除已添加的
    private var availableSuggestions: [String] {
        let currentSet = Set(currentTags)
        return popularTags.filter { !currentSet.contains($0) }.prefix(12).map { $0 }
    }

    // MARK: - Actions

    private func loadTags() {
        do {
            let folderDB = try DatabaseManager.openFolderDatabase(at: sourceFolder)
            currentTags = try folderDB.read { db in
                try TagManager.fetchUserTags(db, clipId: sourceClipId)
            }
            // 从全局库加载热门标签
            if let gdb = globalDB {
                let popular = try gdb.read { db in
                    try TagManager.popularTags(db, limit: 20)
                }
                popularTags = popular.map { $0.tag }
            }
        } catch {
            errorMessage = "加载标签失败: \(error.localizedDescription)"
        }
    }

    private func addNewTags() {
        let input = newTagText
            .split(separator: ",")
            .flatMap { $0.split(separator: "，") } // 中文逗号
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !input.isEmpty else { return }

        for tag in input { addTag(tag) }
        newTagText = ""
    }

    private func addTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !currentTags.contains(trimmed) else { return }

        do {
            let folderDB = try DatabaseManager.openFolderDatabase(at: sourceFolder)
            try folderDB.write { db in
                try TagManager.addTags(db, clipId: sourceClipId, tags: [trimmed])
            }
            currentTags.append(trimmed)
            syncToGlobal()
        } catch {
            errorMessage = "添加标签失败: \(error.localizedDescription)"
        }
    }

    private func removeTag(_ tag: String) {
        do {
            let folderDB = try DatabaseManager.openFolderDatabase(at: sourceFolder)
            try folderDB.write { db in
                try TagManager.removeTags(db, clipId: sourceClipId, tags: [tag])
            }
            currentTags.removeAll { $0 == tag }
            syncToGlobal()
        } catch {
            errorMessage = "移除标签失败: \(error.localizedDescription)"
        }
    }

    /// 增量同步到全局库并刷新搜索
    private func syncToGlobal() {
        guard let gdb = globalDB else { return }
        do {
            let folderDB = try DatabaseManager.openFolderDatabase(at: sourceFolder)
            _ = try SyncEngine.sync(
                folderPath: sourceFolder,
                folderDB: folderDB,
                globalDB: gdb,
                force: true
            )
        } catch {
            print("[TagEditorSheet] 同步失败: \(error)")
        }
    }
}

// MARK: - FlowLayout

/// 简易流式布局（自动换行）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, offset) in result.offsets.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var offsets: [CGPoint]
        var size: CGSize
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var offsets: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return LayoutResult(
            offsets: offsets,
            size: CGSize(width: totalWidth, height: currentY + lineHeight)
        )
    }
}
