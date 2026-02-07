import Foundation
import Vision
import CoreImage

/// 本地视觉分析器 (Apple Vision 框架)
///
/// 使用 macOS 内置 Vision/CoreImage 框架提取图像元数据，
/// 零依赖、零下载、完全离线。可填充 AnalysisResult 的 6/9 字段：
/// scene, subjects, objects, shotType, lighting, colors。
///
/// description、mood、actions 仍需 Gemini API 补充。
public enum LocalVisionAnalyzer {

    /// 本地分析错误
    public enum AnalysisError: LocalizedError, Sendable {
        case imageLoadFailed(path: String)
        case analysisRequestFailed(detail: String)

        public var errorDescription: String? {
            switch self {
            case .imageLoadFailed(let path):
                return "无法加载图片: \(path)"
            case .analysisRequestFailed(let detail):
                return "Vision 分析失败: \(detail)"
            }
        }
    }

    /// 分类标签的最低置信度
    static let classificationThreshold: Float = 0.1

    /// 最多保留的分类标签数
    static let maxClassificationLabels = 8

    /// 共享 CIContext（线程安全，避免每次调用重新分配 GPU 资源）
    private static let sharedCIContext = CIContext()

    // MARK: - 公开接口

    /// 分析单张图片
    ///
    /// 使用 VNClassifyImageRequest 提取场景/物体标签，
    /// VNDetectFace/HumanRectanglesRequest 检测人物，
    /// CIAreaAverage/CIKMeans 提取光线和颜色。
    ///
    /// - Parameter imagePath: JPEG 图片绝对路径
    /// - Returns: 含 6/9 字段的 AnalysisResult
    public static func analyze(imagePath: String) throws -> AnalysisResult {
        let url = URL(fileURLWithPath: imagePath)
        guard let ciImage = CIImage(contentsOf: url) else {
            throw AnalysisError.imageLoadFailed(path: imagePath)
        }

        // 批量执行 Vision requests（一次图像加载，多个分析）
        let handler = VNImageRequestHandler(ciImage: ciImage)

        let classifyRequest = VNClassifyImageRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()

        do {
            try handler.perform([classifyRequest, faceRequest, humanRequest])
        } catch {
            throw AnalysisError.analysisRequestFailed(detail: error.localizedDescription)
        }

        let classifications = classifyRequest.results ?? []
        let faces = faceRequest.results ?? []
        let humans = humanRequest.results ?? []

        let (scene, objects) = extractSceneAndObjects(from: classifications)
        let subjects = inferSubjects(faceCount: faces.count, humanCount: humans.count)
        let shotType = inferShotType(faces: faces)
        let lighting = analyzeLighting(ciImage: ciImage)
        let colors = extractDominantColors(ciImage: ciImage)

        return AnalysisResult(
            scene: scene,
            subjects: subjects,
            actions: [],
            objects: objects,
            mood: nil,
            shotType: shotType,
            lighting: lighting,
            colors: colors,
            description: nil
        )
    }

    /// 分析多张关键帧并合并为单个 clip 的分析结果
    ///
    /// 对每帧独立分析，然后取多数投票（场景/镜头/光线）和并集（人物/物体）。
    /// 单帧分析失败时跳过该帧。
    ///
    /// - Parameter imagePaths: 关键帧图片路径数组
    /// - Returns: 合并后的 AnalysisResult
    public static func analyzeClip(imagePaths: [String]) throws -> AnalysisResult {
        guard !imagePaths.isEmpty else {
            return AnalysisResult(
                scene: nil, subjects: [], actions: [], objects: [],
                mood: nil, shotType: nil, lighting: nil, colors: nil,
                description: nil
            )
        }

        var results: [AnalysisResult] = []
        for path in imagePaths {
            do {
                results.append(try analyze(imagePath: path))
            } catch {
                continue
            }
        }

        guard !results.isEmpty else {
            return AnalysisResult(
                scene: nil, subjects: [], actions: [], objects: [],
                mood: nil, shotType: nil, lighting: nil, colors: nil,
                description: nil
            )
        }

        let scene = mostFrequent(results.compactMap(\.scene))
        let subjects = dedup(results.flatMap(\.subjects))
        let objects = Array(dedup(results.flatMap(\.objects)).prefix(10))
        let shotType = mostFrequent(results.compactMap(\.shotType))
        let lighting = mostFrequent(results.compactMap(\.lighting))
        let colors = results.first(where: { $0.colors != nil })?.colors

        return AnalysisResult(
            scene: scene,
            subjects: subjects,
            actions: [],
            objects: objects,
            mood: nil,
            shotType: shotType,
            lighting: lighting,
            colors: colors,
            description: nil
        )
    }

    /// 将本地分析结果与 Gemini 分析结果合并
    ///
    /// 使用 VisionField.mergeStrategy 决定每个字段的合并策略：
    /// - `.preferNonNil`: remote 非 nil 优先，否则保留 local
    /// - `.preferNonEmptyArray`: remote 非空数组优先，否则保留 local
    ///
    /// - Parameters:
    ///   - local: 本地分析结果
    ///   - remote: Gemini 分析结果
    /// - Returns: 合并后的 AnalysisResult
    public static func mergeResults(local: AnalysisResult, remote: AnalysisResult) -> AnalysisResult {
        func mergeString(_ field: VisionField) -> String? {
            remote.stringValue(for: field) ?? local.stringValue(for: field)
        }

        func mergeArray(_ field: VisionField) -> [String] {
            let remoteArr = remote.arrayValue(for: field)
            let localArr = local.arrayValue(for: field)
            return remoteArr.isEmpty ? localArr : remoteArr
        }

        return AnalysisResult(
            scene: mergeString(.scene),
            subjects: mergeArray(.subjects),
            actions: mergeArray(.actions),
            objects: mergeArray(.objects),
            mood: mergeString(.mood),
            shotType: mergeString(.shotType),
            lighting: mergeString(.lighting),
            colors: mergeString(.colors),
            description: mergeString(.description)
        )
    }

    // MARK: - 分类标签提取

    /// 从 VNClassifyImageRequest 结果提取 scene 和 objects
    ///
    /// 置信度最高的标签 → scene，其余高置信度标签 → objects。
    static func extractSceneAndObjects(
        from observations: [VNClassificationObservation]
    ) -> (scene: String?, objects: [String]) {
        let filtered = observations
            .filter { $0.confidence >= classificationThreshold }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maxClassificationLabels)

        guard let top = filtered.first else {
            return (nil, [])
        }

        let scene = formatLabel(top.identifier)
        let objects = filtered.dropFirst().map { formatLabel($0.identifier) }

        return (scene, Array(objects))
    }

    /// 格式化 VNClassify 标签（下划线 → 空格）
    static func formatLabel(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - 人物检测

    /// 从人脸/人体检测结果推断 subjects
    static func inferSubjects(faceCount: Int, humanCount: Int) -> [String] {
        let personCount = max(faceCount, humanCount)
        guard personCount > 0 else { return [] }

        if personCount == 1 {
            return ["person"]
        } else {
            return ["\(personCount) people"]
        }
    }

    // MARK: - 镜头类型推断

    /// 从人脸边界框推断镜头类型
    ///
    /// 使用最大面部占画面比例推断：
    /// - ECU (极近特写): > 40%
    /// - CU (特写): > 15%
    /// - MCU (中近景): > 5%
    /// - MS (中景): > 1.5%
    /// - WS (全景): < 1.5% 或无人脸
    static func inferShotType(faces: [VNFaceObservation]) -> String? {
        guard !faces.isEmpty else { return "wide shot" }

        let maxFaceRatio = faces.map { face -> Float in
            Float(face.boundingBox.width * face.boundingBox.height)
        }.max() ?? 0

        return classifyShotType(faceAreaRatio: maxFaceRatio)
    }

    /// 根据面部面积占比分类镜头类型（纯函数，可测试）
    static func classifyShotType(faceAreaRatio: Float) -> String {
        switch faceAreaRatio {
        case 0.40...:  return "extreme close-up"
        case 0.15...:  return "close-up"
        case 0.05...:  return "medium close-up"
        case 0.015...: return "medium shot"
        default:       return "wide shot"
        }
    }

    // MARK: - 光线分析

    /// 使用 CIAreaAverage 分析图像平均亮度
    static func analyzeLighting(ciImage: CIImage) -> String? {
        let extent = ciImage.extent

        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ]),
        let outputImage = filter.outputImage else {
            return nil
        }

        var pixel = [Float](repeating: 0, count: 4)
        sharedCIContext.render(outputImage, toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)

        let luminance = 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
        return classifyLighting(luminance: luminance)
    }

    /// 根据亮度值分类光线条件（纯函数，可测试）
    static func classifyLighting(luminance: Float) -> String {
        switch luminance {
        case ..<0.15:  return "very dark"
        case ..<0.3:   return "dark"
        case ..<0.7:   return "normal"
        case ..<0.85:  return "bright"
        default:       return "very bright"
        }
    }

    // MARK: - 主色提取

    /// 使用 CIKMeans 提取主色调，输出命名颜色
    static func extractDominantColors(ciImage: CIImage, count: Int = 5) -> String? {
        let extent = ciImage.extent

        guard let filter = CIFilter(name: "CIKMeans", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: CIVector(cgRect: extent),
            "inputCount": count,
            "inputPasses": 5
        ]),
        let outputImage = filter.outputImage else {
            return nil
        }

        let outputExtent = outputImage.extent
        let width = Int(outputExtent.width)
        guard width > 0 else { return nil }

        var pixels = [Float](repeating: 0, count: width * 4)
        sharedCIContext.render(outputImage, toBitmap: &pixels, rowBytes: width * 16,
                       bounds: outputExtent, format: .RGBAf, colorSpace: nil)

        var colorNames: [String] = []
        var seen = Set<String>()
        for i in 0..<width {
            let r = UInt8(max(0, min(255, pixels[i * 4 + 0] * 255)))
            let g = UInt8(max(0, min(255, pixels[i * 4 + 1] * 255)))
            let b = UInt8(max(0, min(255, pixels[i * 4 + 2] * 255)))
            let name = nearestColorName(r: r, g: g, b: b)
            if !seen.contains(name) {
                seen.insert(name)
                colorNames.append(name)
            }
        }

        return colorNames.isEmpty ? nil : colorNames.joined(separator: " ")
    }

    /// 将 RGB 值映射为命名颜色（便于搜索）
    static func nearestColorName(r: UInt8, g: UInt8, b: UInt8) -> String {
        let rf = Float(r) / 255, gf = Float(g) / 255, bf = Float(b) / 255
        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        let luminance = (maxC + minC) / 2
        let delta = maxC - minC
        let saturation: Float = delta == 0 ? 0 : delta / (1 - abs(2 * luminance - 1))

        if saturation < 0.12 {
            if luminance < 0.2 { return "black" }
            if luminance > 0.8 { return "white" }
            return "gray"
        }

        var hue: Float = 0
        if maxC == rf {
            hue = (gf - bf) / delta
            if hue < 0 { hue += 6 }
        } else if maxC == gf {
            hue = 2 + (bf - rf) / delta
        } else {
            hue = 4 + (rf - gf) / delta
        }
        hue *= 60

        switch hue {
        case ..<15:   return "red"
        case ..<45:   return "orange"
        case ..<75:   return "yellow"
        case ..<150:  return "green"
        case ..<195:  return "cyan"
        case ..<260:  return "blue"
        case ..<290:  return "purple"
        case ..<330:  return "pink"
        default:      return "red"
        }
    }

    // MARK: - 工具方法

    /// 返回数组中出现最多的元素
    static func mostFrequent(_ items: [String]) -> String? {
        guard !items.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for item in items {
            counts[item, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// 去重并保持顺序
    private static func dedup(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
