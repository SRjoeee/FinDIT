import SwiftUI
import FindItCore

/// macOS Settings 页面
///
/// 通过 ⌘, 打开。包含两个 Tab：
/// - 通用：API Key 配置 + 索引选项
/// - 高级：模型参数 + 重置
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("通用", systemImage: "gear") }
            AdvancedTab()
                .tabItem { Label("高级", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - 通用 Tab

private struct GeneralTab: View {
    @State private var apiKey: String = ""
    @State private var apiKeyStatus: APIKeyStatus = .unknown
    @State private var options = IndexingOptions.load()
    @AppStorage("FindIt.showOfflineFiles") private var showOfflineFiles = false

    var body: some View {
        Form {
            apiKeySection
            displaySection
            indexingSection
        }
        .formStyle(.grouped)
        .onAppear { checkAPIKeyStatus() }
    }

    // MARK: API Key

    @ViewBuilder
    private var apiKeySection: some View {
        Section {
            SecureField("Gemini API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveAPIKey() }

            HStack {
                apiKeyStatusView
                Spacer()
                Button("保存") { saveAPIKey() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("API Key")
        } footer: {
            Text("用于 Gemini 视觉分析和向量嵌入。存储在 ~/.config/findit/gemini-api-key.txt")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var apiKeyStatusView: some View {
        switch apiKeyStatus {
        case .valid:
            Label("已配置", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .missing:
            Label("未配置", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .invalid:
            Label("格式无效", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .unknown:
            Label("检测中...", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private func checkAPIKeyStatus() {
        if let key = try? APIKeyManager.resolveAPIKey() {
            apiKey = key
            apiKeyStatus = APIKeyManager.validateAPIKey(key) ? .valid : .invalid
        } else {
            apiKeyStatus = .missing
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try APIKeyManager.saveAPIKey(trimmed)
            apiKeyStatus = APIKeyManager.validateAPIKey(trimmed) ? .valid : .invalid
        } catch {
            apiKeyStatus = .invalid
        }
    }

    // MARK: Display

    @ViewBuilder
    private var displaySection: some View {
        Section {
            Toggle("显示离线文件夹的素材", isOn: $showOfflineFiles)
        } header: {
            Text("显示")
        } footer: {
            Text("关闭时，已断开的外接硬盘等离线文件夹的素材不会出现在搜索结果中。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Indexing Options

    @ViewBuilder
    private var indexingSection: some View {
        Section("索引选项") {
            Toggle("语音转录 (STT)", isOn: Binding(
                get: { !options.skipStt },
                set: { options.skipStt = !$0; options.save() }
            ))

            Toggle("云端视觉分析 (Gemini)", isOn: Binding(
                get: { !options.skipVision },
                set: { options.skipVision = !$0; options.save() }
            ))

            Toggle("向量嵌入", isOn: Binding(
                get: { !options.skipEmbedding },
                set: { options.skipEmbedding = !$0; options.save() }
            ))

            Picker("性能模式", selection: Binding(
                get: { options.performanceMode },
                set: { options.performanceMode = $0; options.save() }
            )) {
                ForEach(PerformanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Stepper("删除保留: \(options.orphanedRetentionDays) 天", value: Binding(
                get: { options.orphanedRetentionDays },
                set: { options.orphanedRetentionDays = $0; options.save() }
            ), in: 0...365)
            Text("视频文件删除后索引数据保留的天数，0 为立即清除")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 高级 Tab

private struct AdvancedTab: View {
    @State private var config = ProviderConfig.load()

    var body: some View {
        Form {
            visionSection
            embeddingSection
            rateLimitSection
            resetSection
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var visionSection: some View {
        Section("视觉分析模型") {
            TextField("模型名称", text: $config.visionModel)
                .textFieldStyle(.roundedBorder)
                .onChange(of: config.visionModel) { config.save() }

            Stepper("每请求最大图片数: \(config.visionMaxImages)",
                    value: $config.visionMaxImages, in: 1...20)
                .onChange(of: config.visionMaxImages) { config.save() }

            Stepper("请求超时: \(Int(config.visionTimeout))秒",
                    value: $config.visionTimeout, in: 10...300, step: 10)
                .onChange(of: config.visionTimeout) { config.save() }

            Stepper("最大重试次数: \(config.visionMaxRetries)",
                    value: $config.visionMaxRetries, in: 0...10)
                .onChange(of: config.visionMaxRetries) { config.save() }
        }
    }

    @ViewBuilder
    private var embeddingSection: some View {
        Section("嵌入模型") {
            TextField("模型名称", text: $config.embeddingModel)
                .textFieldStyle(.roundedBorder)
                .onChange(of: config.embeddingModel) { config.save() }

            Stepper("向量维度: \(config.embeddingDimensions)",
                    value: $config.embeddingDimensions, in: 128...2048, step: 128)
                .onChange(of: config.embeddingDimensions) { config.save() }
        }
    }

    @ViewBuilder
    private var rateLimitSection: some View {
        Section {
            Stepper("每分钟请求数: \(config.rateLimitRPM)",
                    value: $config.rateLimitRPM, in: 1...60)
                .onChange(of: config.rateLimitRPM) { config.save() }
        } header: {
            Text("速率限制")
        } footer: {
            Text("Gemini 免费额度约 10 RPM。设置过高可能导致 429 限流。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button("恢复默认设置") {
                ProviderConfig.resetToDefault()
                config = ProviderConfig.default
            }
        }
    }
}

// MARK: - 辅助类型

private enum APIKeyStatus {
    case valid
    case missing
    case invalid
    case unknown
}
