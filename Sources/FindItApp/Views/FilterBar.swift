import SwiftUI
import FindItCore

/// 搜索结果筛选过滤栏
///
/// 水平排列的过滤菜单 + 排序选择 + 清除按钮。
/// 活跃的过滤器以着色 pill 展示。
struct FilterBar: View {
    @Binding var filter: FilterEngine.SearchFilter
    let facets: FilterEngine.FacetCounts?

    var body: some View {
        HStack(spacing: 6) {
            // 评分
            Menu {
                Button("不限") { filter.minRating = nil }
                Divider()
                ForEach(1...5, id: \.self) { stars in
                    Button {
                        filter.minRating = stars
                    } label: {
                        HStack {
                            if filter.minRating == stars {
                                Image(systemName: "checkmark")
                            }
                            Text("\(stars)+ 星")
                        }
                    }
                }
            } label: {
                filterPill(
                    icon: "star.fill",
                    text: filter.minRating.map { "\($0)+" } ?? "评分",
                    isActive: filter.minRating != nil
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // 颜色
            Menu {
                Button("不限") { filter.colorLabels = nil }
                Divider()
                ForEach(ColorLabel.allCases, id: \.rawValue) { label in
                    Button {
                        toggleColor(label)
                    } label: {
                        HStack {
                            if filter.colorLabels?.contains(label) == true {
                                Image(systemName: "checkmark")
                            }
                            Circle()
                                .fill(Color(red: label.rgb.r, green: label.rgb.g, blue: label.rgb.b))
                                .frame(width: 10, height: 10)
                            Text(label.displayName)
                        }
                    }
                }
            } label: {
                filterPill(
                    icon: "circle.fill",
                    text: colorLabelText,
                    isActive: filter.colorLabels != nil
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // 镜头类型（仅在有可用值时显示）
            if let facets = facets, !facets.shotTypes.isEmpty {
                Menu {
                    Button("不限") { filter.shotTypes = nil }
                    Divider()
                    ForEach(facets.shotTypes, id: \.value) { item in
                        Button {
                            toggleShotType(item.value)
                        } label: {
                            HStack {
                                if filter.shotTypes?.contains(item.value) == true {
                                    Image(systemName: "checkmark")
                                }
                                Text("\(item.value) (\(item.count))")
                            }
                        }
                    }
                } label: {
                    filterPill(
                        icon: "camera.metering.spot",
                        text: shotTypeText,
                        isActive: filter.shotTypes != nil
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // 情绪（仅在有可用值时显示）
            if let facets = facets, !facets.moods.isEmpty {
                Menu {
                    Button("不限") { filter.moods = nil }
                    Divider()
                    ForEach(facets.moods, id: \.value) { item in
                        Button {
                            toggleMood(item.value)
                        } label: {
                            HStack {
                                if filter.moods?.contains(item.value) == true {
                                    Image(systemName: "checkmark")
                                }
                                Text("\(item.value) (\(item.count))")
                            }
                        }
                    }
                } label: {
                    filterPill(
                        icon: "theatermask.and.paintbrush",
                        text: moodText,
                        isActive: filter.moods != nil
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            // 排序
            Menu {
                ForEach(FilterEngine.SortField.allCases, id: \.rawValue) { field in
                    Button {
                        if filter.sortBy == field {
                            // 再次点击切换方向
                            filter.sortOrder = filter.sortOrder == .descending ? .ascending : .descending
                        } else {
                            filter.sortBy = field
                            filter.sortOrder = .descending
                        }
                    } label: {
                        HStack {
                            if filter.sortBy == field {
                                Image(systemName: filter.sortOrder == .ascending ? "chevron.up" : "chevron.down")
                            }
                            Text(field.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(filter.sortBy.displayName)
                    if filter.sortBy != .relevance {
                        Image(systemName: filter.sortOrder == .ascending ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                }
                .font(.caption)
                .foregroundStyle(filter.sortBy != .relevance ? Color.accentColor : .secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // 清除
            if !filter.isEmpty {
                Button {
                    filter = FilterEngine.SearchFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除所有过滤")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Pill 样式

    @ViewBuilder
    private func filterPill(icon: String, text: String, isActive: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
    }

    // MARK: - Label 文本

    private var colorLabelText: String {
        guard let colors = filter.colorLabels, !colors.isEmpty else { return "颜色" }
        if colors.count == 1, let first = colors.first { return first.displayName }
        return "\(colors.count) 色"
    }

    private var shotTypeText: String {
        guard let shots = filter.shotTypes, !shots.isEmpty else { return "镜头" }
        if shots.count == 1, let first = shots.first { return first }
        return "\(shots.count) 种"
    }

    private var moodText: String {
        guard let moods = filter.moods, !moods.isEmpty else { return "情绪" }
        if moods.count == 1, let first = moods.first { return first }
        return "\(moods.count) 种"
    }

    // MARK: - Toggle 操作

    private func toggleColor(_ label: ColorLabel) {
        var colors = filter.colorLabels ?? []
        if colors.contains(label) {
            colors.remove(label)
            filter.colorLabels = colors.isEmpty ? nil : colors
        } else {
            colors.insert(label)
            filter.colorLabels = colors
        }
    }

    private func toggleShotType(_ value: String) {
        var shots = filter.shotTypes ?? []
        if shots.contains(value) {
            shots.remove(value)
            filter.shotTypes = shots.isEmpty ? nil : shots
        } else {
            shots.insert(value)
            filter.shotTypes = shots
        }
    }

    private func toggleMood(_ value: String) {
        var moods = filter.moods ?? []
        if moods.contains(value) {
            moods.remove(value)
            filter.moods = moods.isEmpty ? nil : moods
        } else {
            moods.insert(value)
            filter.moods = moods
        }
    }
}
