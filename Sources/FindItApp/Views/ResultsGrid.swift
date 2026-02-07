import SwiftUI
import FindItCore

/// 搜索结果网格
///
/// 使用 LazyVGrid 自适应布局展示搜索结果卡片。
/// 列数随窗口宽度自动调整（最小卡片宽度 200px）。
struct ResultsGrid: View {
    let results: [SearchEngine.SearchResult]
    let resultCount: Int

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 400), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(results, id: \.clipId) { result in
                    ClipCard(result: result)
                }
            }
            .padding(16)
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text("\(resultCount) 个片段")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
    }
}
