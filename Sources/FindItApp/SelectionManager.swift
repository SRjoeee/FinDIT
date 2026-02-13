import AppKit
import FindItCore

/// 网格选择状态 + 键盘交互逻辑
///
/// 从 ContentView 提取的选择管理器，集中管理：
/// - 选中/焦点/锚点状态
/// - 方向键导航、空格预览、全选/取消选中
///
/// QuickLookCoordinator 的 event monitor 直接调用本类方法，
/// 消除了原先通过 NotificationCenter 中转的间接路径。
@Observable @MainActor
final class SelectionManager {

    // MARK: - 选择状态

    var selectedClipIds: Set<Int64> = []
    var focusedClipId: Int64?
    var selectionAnchorId: Int64?
    var scrollOnSelect = false
    var columnsPerRow: Int = 3

    // MARK: - 依赖（.task 中注入）

    weak var searchState: SearchState?
    weak var qlCoordinator: QuickLookCoordinator?

    // MARK: - 计算属性

    /// 当前选中的搜索结果
    var selectedResults: [SearchEngine.SearchResult] {
        guard let searchState else { return [] }
        return searchState.visibleResults.filter { selectedClipIds.contains($0.clipId) }
    }

    // MARK: - 键盘交互

    /// 方向键：网格导航
    ///
    /// 左/右移动 ±1，上/下按列数跳行。
    /// 无选中时按任意方向键选中第一项。
    /// Shift+方向键扩展选中范围。
    func handleArrowKey(_ direction: NavigationDirection, modifiers: NSEvent.ModifierFlags = []) {
        guard let searchState else { return }
        let results = searchState.visibleResults
        guard !results.isEmpty else { return }

        // 无焦点 → 选第一项
        guard let currentId = focusedClipId,
              let currentIndex = results.firstIndex(where: { $0.clipId == currentId }) else {
            let firstId = results[0].clipId
            scrollOnSelect = true
            focusedClipId = firstId
            selectedClipIds = [firstId]
            selectionAnchorId = firstId
            return
        }

        let newIndex: Int
        switch direction {
        case .left:
            newIndex = max(0, currentIndex - 1)
        case .right:
            newIndex = min(results.count - 1, currentIndex + 1)
        case .up:
            newIndex = max(0, currentIndex - columnsPerRow)
        case .down:
            newIndex = min(results.count - 1, currentIndex + columnsPerRow)
        }

        guard newIndex != currentIndex else { return }
        let newId = results[newIndex].clipId
        scrollOnSelect = true
        focusedClipId = newId

        if modifiers.contains(.shift) {
            // Shift+方向键：扩展选中
            selectedClipIds.insert(newId)
        } else {
            // 普通方向键：单选
            selectedClipIds = [newId]
            selectionAnchorId = newId
        }
    }

    /// 空格键：切换预览（使用焦点 clip）
    ///
    /// 视频文件 → VideoPreviewPanel（seek 到 startTime），
    /// 其他文件 → QLPreviewPanel。
    func handleSpaceKey() {
        guard let searchState, let qlCoordinator else { return }
        guard let clipId = focusedClipId,
              let result = searchState.visibleResults.first(where: { $0.clipId == clipId }),
              let path = result.filePath,
              FileManager.default.fileExists(atPath: path) else { return }
        let info = ClipPreviewInfo(
            url: URL(fileURLWithPath: path),
            startTime: result.startTime,
            endTime: result.endTime,
            isVideo: FileScanner.isVideoFile(path)
        )
        qlCoordinator.toggle(info: info)
    }

    /// ⌘A：全选当前可见结果
    func handleSelectAll() {
        guard let searchState else { return }
        let results = searchState.visibleResults
        guard !results.isEmpty else { return }
        selectedClipIds = Set(results.map(\.clipId))
        if focusedClipId == nil {
            focusedClipId = results[0].clipId
        }
    }

    /// Escape：清空选中
    func handleDeselectAll() {
        selectedClipIds = []
        focusedClipId = nil
        selectionAnchorId = nil
    }

    // MARK: - 鼠标点击

    /// Finder 风格的点击选中逻辑
    ///
    /// ⌘+Click toggle、⇧+Click 范围选、普通 Click 单选。
    func handleClick(clipId: Int64, modifiers: NSEvent.ModifierFlags) {
        guard let searchState else { return }
        let results = searchState.visibleResults

        if modifiers.contains(.command) {
            // ⌘+Click: toggle
            if selectedClipIds.contains(clipId) {
                selectedClipIds.remove(clipId)
                if focusedClipId == clipId {
                    focusedClipId = selectedClipIds.first
                }
            } else {
                selectedClipIds.insert(clipId)
                focusedClipId = clipId
            }
            selectionAnchorId = clipId
        } else if modifiers.contains(.shift), let anchorId = selectionAnchorId {
            // ⇧+Click: 范围选中
            guard let anchorIndex = results.firstIndex(where: { $0.clipId == anchorId }),
                  let clickIndex = results.firstIndex(where: { $0.clipId == clipId }) else {
                // Fallback: 单选
                selectedClipIds = [clipId]
                focusedClipId = clipId
                selectionAnchorId = clipId
                return
            }
            let range = min(anchorIndex, clickIndex)...max(anchorIndex, clickIndex)
            selectedClipIds = Set(results[range].map(\.clipId))
            focusedClipId = clipId
            // Shift+Click 不更新 anchor (Finder 行为)
        } else {
            // 普通点击: 单选
            selectedClipIds = [clipId]
            focusedClipId = clipId
            selectionAnchorId = clipId
        }
    }

    /// 搜索词变更时清空选中
    func clearSelection() {
        selectedClipIds = []
        focusedClipId = nil
        selectionAnchorId = nil
    }

    /// 焦点变更时更新预览面板
    ///
    /// 点击卡片时让搜索框失焦，event monitor 可处理后续键盘事件。
    /// 预览面板已打开时，焦点变更自动更新预览。
    func updatePreviewIfNeeded() {
        if focusedClipId != nil {
            let window = NSApp.keyWindow
            if window?.firstResponder is NSTextView {
                window?.makeFirstResponder(nil)
            }
        }
        guard let searchState, let qlCoordinator else { return }
        guard let clipId = focusedClipId,
              let result = searchState.visibleResults.first(where: { $0.clipId == clipId }),
              let path = result.filePath,
              FileManager.default.fileExists(atPath: path) else { return }
        let info = ClipPreviewInfo(
            url: URL(fileURLWithPath: path),
            startTime: result.startTime,
            endTime: result.endTime,
            isVideo: FileScanner.isVideoFile(path)
        )
        qlCoordinator.updateIfVisible(info: info)
    }
}
