import SwiftUI
import FindItCore

/// macOS Settings 页面
///
/// 通过 ⌘, 打开。包含两个 Tab：
/// - 通用：API Key 配置 + 索引选项
/// - 高级：模型参数 + 重置
struct SettingsView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(SubscriptionManager.self) private var subscriptionManager

    var body: some View {
        TabView {
            GeneralTab(authManager: authManager, subscriptionManager: subscriptionManager)
                .tabItem { Label("通用", systemImage: "gear") }
            AdvancedTab()
                .tabItem { Label("高级", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 480, height: 580)
    }
}

// MARK: - 通用 Tab

private struct GeneralTab: View {
    let authManager: AuthManager
    let subscriptionManager: SubscriptionManager

    @State private var apiKey: String = ""
    @State private var apiKeyStatus: APIKeyStatus = .unknown
    @State private var options = IndexingOptions.load()
    @State private var config = ProviderConfig.load()
    @State private var showLoginSheet = false
    @State private var isSigningOut = false
    @AppStorage("FindIt.showOfflineFiles") private var showOfflineFiles = false

    private var provider: APIProvider { config.provider }

    /// 是否使用订阅 Key（隐藏手动 API Key 配置）
    private var isUsingSubscription: Bool {
        authManager.isAuthenticated && subscriptionManager.isCloudEnabled
    }

    var body: some View {
        Form {
            accountSection
            cloudModeSection
            if !isUsingSubscription {
                apiKeySection
                    .disabled(options.cloudMode == .local)
                    .opacity(options.cloudMode == .local ? 0.5 : 1.0)
            }
            displaySection
            sttSection
            performanceSection
        }
        .formStyle(.grouped)
        .onAppear { checkAPIKeyStatus() }
        .sheet(isPresented: $showLoginSheet) {
            LoginSheet(authManager: authManager)
        }
    }

    // MARK: Account

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if authManager.isAuthenticated {
                // 已登录
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(authManager.currentEmail ?? "已登录")
                            .font(.body)
                        HStack(spacing: 6) {
                            planBadge
                            if let usage = subscriptionManager.usageText {
                                Text(usage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer()
                    if subscriptionManager.currentPlan != .pro {
                        Button("升级 Pro") {
                            Task { await openCheckout() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                if let days = subscriptionManager.trialDaysRemaining {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .foregroundStyle(.orange)
                        Text("试用剩余 \(days) 天")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if subscriptionManager.isPastDue {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("付款失败，请更新支付方式")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                HStack {
                    if subscriptionManager.currentPlan == .pro {
                        Button("管理订阅") {
                            Task { await openBillingPortal() }
                        }
                    }
                    Spacer()
                    Button("退出登录") {
                        Task { await signOut() }
                    }
                    .disabled(isSigningOut)
                }
            } else {
                // 未登录
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("未登录")
                            .font(.body)
                        Text("登录后享 14 天云端 AI 免费试用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("登录") { showLoginSheet = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        } header: {
            Text("账户")
        }
    }

    @ViewBuilder
    private var planBadge: some View {
        let (text, color): (String, Color) = switch subscriptionManager.currentPlan {
        case .pro: ("Pro", .blue)
        case .trial: ("Trial", .orange)
        case .free: ("Free", .secondary)
        }
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func openCheckout() async {
        do {
            let url = try await subscriptionManager.checkoutURL()
            NSWorkspace.shared.open(url)
        } catch {
            print("[Settings] Checkout error: \(error)")
        }
    }

    private func openBillingPortal() async {
        do {
            let url = try await subscriptionManager.billingPortalURL()
            NSWorkspace.shared.open(url)
        } catch {
            print("[Settings] Billing portal error: \(error)")
        }
    }

    private func signOut() async {
        isSigningOut = true
        do {
            try await authManager.signOut()
            subscriptionManager.clearCache()
            // cloudMode 自动降级：订阅 Key 不再可用，IndexingManager 下次 resolve 会回退到文件 Key
        } catch {
            print("[Settings] Sign out error: \(error)")
        }
        isSigningOut = false
    }

    // MARK: API Key

    @ViewBuilder
    private var apiKeySection: some View {
        Section {
            SecureField("\(provider.displayName) API Key", text: $apiKey)
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
            if options.cloudMode == .local {
                Text("纯本地模式无需 API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("用于视觉分析和向量嵌入。存储在 \(provider.keyFilePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        // 重新加载 config 以获取最新 provider
        config = ProviderConfig.load()
        if let key = try? APIKeyManager.resolveAPIKey(provider: provider) {
            apiKey = key
            apiKeyStatus = APIKeyManager.validateAPIKey(key) ? .valid : .invalid
        } else {
            apiKey = ""
            apiKeyStatus = .missing
        }
    }

    private func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            try APIKeyManager.saveAPIKey(trimmed, provider: provider)
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

    // MARK: Cloud Mode

    @ViewBuilder
    private var cloudModeSection: some View {
        Section {
            if isUsingSubscription {
                // 订阅用户：云端模式可切换
                Picker("索引模式", selection: Binding(
                    get: { options.cloudMode },
                    set: { options.cloudMode = $0; options.save() }
                )) {
                    ForEach(CloudMode.allCases, id: \.self) { mode in
                        Text(mode.displayLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } else if authManager.isAuthenticated && !subscriptionManager.isCloudEnabled {
                // 已登录但无云端权限（Free/Trial 过期）
                HStack {
                    Text("纯本地模式")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("升级解锁云端") {
                        Task { await openCheckout() }
                    }
                    .controlSize(.small)
                }
            } else {
                // 未登录：手动 API Key 模式仍可选
                Picker("索引模式", selection: Binding(
                    get: { options.cloudMode },
                    set: { options.cloudMode = $0; options.save() }
                )) {
                    ForEach(CloudMode.allCases, id: \.self) { mode in
                        Text(mode.displayLabel).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if options.cloudMode == .local && !isUsingSubscription {
                Toggle("启用 LocalVLM 深度分析", isOn: Binding(
                    get: { options.useLocalVLM },
                    set: { options.useLocalVLM = $0; options.save() }
                ))
                Text("使用本地 AI 模型分析视频内容 (需下载 ~3GB 模型，推理 ~5-10s/片段)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("索引模式")
        } footer: {
            if isUsingSubscription {
                Text("订阅已激活，云端模式使用 OpenRouter API 进行视觉分析和文本嵌入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(options.cloudMode.descriptionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: STT Options

    @ViewBuilder
    private var sttSection: some View {
        Section("语音转录") {
            Toggle("启用语音转录 (STT)", isOn: Binding(
                get: { !options.skipStt },
                set: { options.skipStt = !$0; options.save() }
            ))

            Picker("STT 引擎", selection: Binding(
                get: { options.sttEngine },
                set: { options.sttEngine = $0; options.save() }
            )) {
                ForEach(STTEngine.allCases, id: \.self) { engine in
                    Text(engine.displayLabel).tag(engine)
                }
            }
            .disabled(options.skipStt)

            Picker("STT 语言", selection: Binding(
                get: { options.sttLanguageHint ?? "auto" },
                set: {
                    options.sttLanguageHint = ($0 == "auto") ? nil : $0
                    options.save()
                }
            )) {
                Text("自动检测").tag("auto")
                Divider()
                Text("英语 (English)").tag("en")
                Text("日语 (日本語)").tag("ja")
                Text("中文 (中文)").tag("zh")
                Text("韩语 (한국어)").tag("ko")
                Text("法语 (Français)").tag("fr")
                Text("德语 (Deutsch)").tag("de")
                Text("西班牙语 (Español)").tag("es")
            }
            .disabled(options.skipStt)

            Toggle("在 Finder 中隐藏 SRT 字幕文件", isOn: Binding(
                get: { options.hideSrtFiles },
                set: { newValue in
                    let oldValue = options.hideSrtFiles
                    options.hideSrtFiles = newValue
                    options.save()
                    if oldValue != newValue {
                        NotificationCenter.default.post(
                            name: .srtVisibilityChanged,
                            object: nil,
                            userInfo: ["hidden": newValue]
                        )
                    }
                }
            ))
            .disabled(options.skipStt)
            Text("SRT 始终生成用于搜索，此选项仅控制 Finder 中是否可见")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Performance

    @ViewBuilder
    private var performanceSection: some View {
        Section("性能与数据") {
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
    @Environment(AuthManager.self) private var authManager
    @Environment(SubscriptionManager.self) private var subscriptionManager
    @State private var config = ProviderConfig.load()

    /// 订阅模式下禁用手动配置
    private var isUsingSubscription: Bool {
        authManager.isAuthenticated && subscriptionManager.isCloudEnabled
    }

    /// 自定义 Base URL 绑定
    private var useCustomURL: Binding<Bool> {
        Binding(
            get: { config.baseURL != nil },
            set: { newValue in
                if newValue {
                    config.baseURL = config.provider.defaultBaseURL
                } else {
                    config.baseURL = nil
                }
                config.save()
            }
        )
    }

    private var customBaseURL: Binding<String> {
        Binding(
            get: { config.baseURL ?? config.provider.defaultBaseURL },
            set: { config.baseURL = $0; config.save() }
        )
    }

    var body: some View {
        Form {
            if isUsingSubscription {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("订阅模式下使用 OpenRouter 托管配置，无需手动调整。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            providerSection
            visionSection
            embeddingSection
            rateLimitSection
            resetSection
        }
        .formStyle(.grouped)
        .disabled(isUsingSubscription)
        .opacity(isUsingSubscription ? 0.6 : 1.0)
    }

    // MARK: Provider

    @ViewBuilder
    private var providerSection: some View {
        Section {
            Picker("API 提供者", selection: $config.provider) {
                ForEach(APIProvider.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .onChange(of: config.provider) { config.save() }

            Toggle("自定义 Base URL", isOn: useCustomURL)

            if config.baseURL != nil {
                TextField("Base URL", text: customBaseURL)
                    .textFieldStyle(.roundedBorder)
            }
        } header: {
            Text("API 提供者")
        } footer: {
            Text("切换提供者后需在「通用」页面重新配置对应的 API Key。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            Text(config.provider == .gemini
                 ? "Gemini 免费额度约 10 RPM。设置过高可能导致 429 限流。"
                 : "根据 OpenRouter 套餐调整。设置过高可能导致限流。")
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
