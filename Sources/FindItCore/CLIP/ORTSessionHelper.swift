import Foundation
import OnnxRuntimeBindings

/// ORT Session 创建辅助 — 共享 CoreML EP 配置
///
/// 统一管理 ONNX Runtime session 的创建逻辑：
/// - Apple Silicon 上自动启用 CoreML Execution Provider（ANE 加速）
/// - CoreML EP 不可用或启用失败时透明回退 CPU
/// - 3 个编码器（SigLIP2 Image/Text + EmbeddingGemma）共享此配置
public enum ORTSessionHelper {

    /// CoreML EP 是否可用（运行时检查）
    public static var isCoreMLAvailable: Bool {
        ORTIsCoreMLExecutionProviderAvailable()
    }

    /// 创建带 CoreML EP 的 session options
    ///
    /// - Parameter graphOptimizationLevel: 图优化级别
    ///   - FP16 模型（SigLIP2）必须用 `.none`
    ///   - Q8 模型（EmbeddingGemma）可用 `.all`
    /// - Returns: 配置好的 ORTSessionOptions
    public static func makeSessionOptions(
        graphOptimizationLevel: ORTGraphOptimizationLevel
    ) throws -> ORTSessionOptions {
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(graphOptimizationLevel)

        if ORTIsCoreMLExecutionProviderAvailable() {
            let coreMLOpts = ORTCoreMLExecutionProviderOptions()
            coreMLOpts.onlyAllowStaticInputShapes = true
            coreMLOpts.createMLProgram = true
            coreMLOpts.enableOnSubgraphs = true
            do {
                try options.appendCoreMLExecutionProvider(with: coreMLOpts)
            } catch {
                // CoreML EP 启用失败不致命 — 静默回退 CPU
            }
        }

        return options
    }

    /// 一步创建 ORTEnv + ORTSession（带 CoreML EP）
    ///
    /// - Parameters:
    ///   - modelPath: ONNX 模型文件路径
    ///   - graphOptimizationLevel: 图优化级别
    /// - Returns: (env, session) 元组，调用方需保留 env 引用
    public static func createSession(
        modelPath: String,
        graphOptimizationLevel: ORTGraphOptimizationLevel
    ) throws -> (env: ORTEnv, session: ORTSession) {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try makeSessionOptions(graphOptimizationLevel: graphOptimizationLevel)
        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        return (env, session)
    }
}
