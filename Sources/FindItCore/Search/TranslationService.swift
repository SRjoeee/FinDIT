import Foundation

// MARK: - TranslationService Protocol

/// 翻译服务协议
///
/// 为查询扩展提供跨语言翻译能力。
/// 实现方包括本地词典（始终可用）和 Apple Translation（macOS 15+）。
public protocol TranslationService: Sendable {
    /// 翻译文本
    ///
    /// - Parameters:
    ///   - text: 源文本
    ///   - source: 源语言代码 (如 "zh-Hans", "en")
    ///   - target: 目标语言代码
    /// - Returns: 翻译结果，nil 表示无法翻译
    func translate(_ text: String, from source: String, to target: String) async throws -> String?

    /// 翻译服务是否可用
    var isAvailable: Bool { get }
}

// MARK: - TranslationDictionary

/// 本地双向词典翻译
///
/// ~200 个视频制作常用术语的中英双向词典，覆盖:
/// 自然景观、人物、动作、镜头类型、氛围、物体、场景。
///
/// 翻译策略: CJK 文本先分词（NLTokenizer），逐词查表，
/// 未命中的词保留原样（不丢信息）。
///
/// 始终可用（macOS 14+），作为 Apple Translation 的回退。
public final class TranslationDictionary: TranslationService, @unchecked Sendable {

    /// 全局共享实例
    public static let shared = TranslationDictionary()

    /// 中文 → 英文
    let zhToEn: [String: String]
    /// 英文 → 中文（小写 key）
    let enToZh: [String: String]

    public init() {
        let pairs = Self.buildDictionary()
        var zh2en: [String: String] = [:]
        var en2zh: [String: String] = [:]
        for (zh, en) in pairs {
            zh2en[zh] = en
            en2zh[en.lowercased()] = zh
        }
        self.zhToEn = zh2en
        self.enToZh = en2zh
    }

    public var isAvailable: Bool { true }

    // MARK: - TranslationService

    public func translate(
        _ text: String, from source: String, to target: String
    ) async throws -> String? {
        translateSync(text, from: source, to: target)
    }

    // MARK: - Sync Translation

    /// 同步翻译（QueryPipeline.expandSync 调用）
    ///
    /// CJK → EN: 分词后逐词查表
    /// EN → ZH: 按空格分词后逐词查表
    ///
    /// - Returns: 翻译结果，nil 表示完全没命中
    public func translateSync(
        _ text: String, from source: String, to target: String
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isCJKSource = Self.cjkCodes.contains(source)

        if isCJKSource && target == "en" {
            return translateCJKToEN(trimmed)
        } else if source == "en" && Self.cjkCodes.contains(target) {
            return translateENToZH(trimmed)
        }

        return nil
    }

    // MARK: - Private Translation

    /// CJK → EN 翻译
    private func translateCJKToEN(_ text: String) -> String? {
        let tokens = QueryPipeline.segmentCJK(text)
        guard !tokens.isEmpty else { return nil }

        var translated: [String] = []
        var anyHit = false

        for token in tokens {
            if let en = zhToEn[token] {
                translated.append(en)
                anyHit = true
            } else {
                // 未命中保留原词
                translated.append(token)
            }
        }

        guard anyHit else { return nil }
        return translated.joined(separator: " ")
    }

    /// EN → ZH 翻译
    private func translateENToZH(_ text: String) -> String? {
        // 英文按空格分词，尝试多词短语和单词匹配
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        var translated: [String] = []
        var anyHit = false
        var i = 0

        while i < words.count {
            // 尝试三词短语
            if i + 2 < words.count {
                let threeWord = "\(words[i]) \(words[i+1]) \(words[i+2])"
                if let zh = enToZh[threeWord] {
                    translated.append(zh)
                    anyHit = true
                    i += 3
                    continue
                }
            }
            // 尝试双词短语
            if i + 1 < words.count {
                let twoWord = "\(words[i]) \(words[i+1])"
                if let zh = enToZh[twoWord] {
                    translated.append(zh)
                    anyHit = true
                    i += 2
                    continue
                }
            }
            // 单词匹配
            if let zh = enToZh[words[i]] {
                translated.append(zh)
                anyHit = true
            } else {
                translated.append(words[i])
            }
            i += 1
        }

        guard anyHit else { return nil }
        return translated.joined(separator: " ")
    }

    /// CJK 语言代码集合
    private static let cjkCodes: Set<String> = [
        "zh-Hans", "zh-Hant", "ja", "ko"
    ]

    // MARK: - Dictionary Data

    /// 构建双向词典 (~200 词对)
    ///
    /// 格式: (中文, 英文)
    private static func buildDictionary() -> [(String, String)] {
        // swiftlint:disable line_length
        return [
            // ── 自然景观 ──
            ("海滩", "beach"),
            ("海", "ocean"),
            ("大海", "ocean"),
            ("海洋", "ocean"),
            ("日落", "sunset"),
            ("日出", "sunrise"),
            ("森林", "forest"),
            ("山", "mountain"),
            ("山脉", "mountains"),
            ("天空", "sky"),
            ("雪", "snow"),
            ("河", "river"),
            ("河流", "river"),
            ("湖", "lake"),
            ("湖泊", "lake"),
            ("沙漠", "desert"),
            ("草地", "grass"),
            ("草原", "grassland"),
            ("花", "flower"),
            ("花朵", "flower"),
            ("云", "cloud"),
            ("云朵", "cloud"),
            ("雨", "rain"),
            ("风", "wind"),
            ("瀑布", "waterfall"),
            ("岛", "island"),
            ("岛屿", "island"),
            ("礁石", "reef"),
            ("星空", "starry sky"),
            ("月亮", "moon"),
            ("太阳", "sun"),
            ("彩虹", "rainbow"),
            ("雾", "fog"),
            ("冰", "ice"),
            ("波浪", "wave"),
            ("海浪", "wave"),

            // ── 人物 ──
            ("人", "person"),
            ("人物", "person"),
            ("女人", "woman"),
            ("女性", "woman"),
            ("男人", "man"),
            ("男性", "man"),
            ("孩子", "child"),
            ("小孩", "child"),
            ("儿童", "child"),
            ("老人", "elderly"),
            ("婴儿", "baby"),
            ("家庭", "family"),
            ("情侣", "couple"),
            ("朋友", "friends"),
            ("人群", "crowd"),
            ("运动员", "athlete"),
            ("模特", "model"),

            // ── 动作 ──
            ("走", "walk"),
            ("走路", "walking"),
            ("跑", "run"),
            ("跑步", "running"),
            ("跳", "jump"),
            ("跳跃", "jumping"),
            ("游泳", "swimming"),
            ("舞蹈", "dance"),
            ("跳舞", "dancing"),
            ("吃", "eat"),
            ("吃饭", "eating"),
            ("喝", "drink"),
            ("喝水", "drinking"),
            ("开车", "driving"),
            ("骑车", "cycling"),
            ("飞", "fly"),
            ("飞行", "flying"),
            ("爬", "climb"),
            ("攀爬", "climbing"),
            ("坐", "sit"),
            ("站", "stand"),
            ("躺", "lie down"),
            ("睡", "sleep"),
            ("睡觉", "sleeping"),
            ("唱歌", "singing"),
            ("弹琴", "playing piano"),
            ("画画", "painting"),
            ("拍照", "taking photos"),
            ("做饭", "cooking"),
            ("购物", "shopping"),
            ("工作", "working"),
            ("学习", "studying"),
            ("旅行", "traveling"),
            ("冲浪", "surfing"),
            ("滑雪", "skiing"),
            ("潜水", "diving"),
            ("钓鱼", "fishing"),
            ("露营", "camping"),
            ("打球", "playing ball"),

            // ── 镜头类型 ──
            ("全景", "wide shot"),
            ("远景", "long shot"),
            ("特写", "close-up"),
            ("中景", "medium shot"),
            ("航拍", "aerial"),
            ("俯拍", "overhead shot"),
            ("仰拍", "low angle"),
            ("慢动作", "slow motion"),
            ("延时", "timelapse"),
            ("延时摄影", "timelapse"),
            ("跟拍", "tracking shot"),
            ("手持", "handheld"),
            ("稳定器", "gimbal"),
            ("推拉", "zoom"),
            ("摇镜", "pan"),
            ("升格", "high frame rate"),

            // ── 氛围与光线 ──
            ("明亮", "bright"),
            ("暗", "dark"),
            ("黑暗", "dark"),
            ("暖", "warm"),
            ("温暖", "warm"),
            ("冷", "cold"),
            ("安静", "quiet"),
            ("热闹", "lively"),
            ("浪漫", "romantic"),
            ("悲伤", "sad"),
            ("快乐", "happy"),
            ("紧张", "tense"),
            ("恐怖", "horror"),
            ("神秘", "mysterious"),
            ("梦幻", "dreamy"),
            ("复古", "vintage"),
            ("现代", "modern"),
            ("金色", "golden"),
            ("蓝色", "blue"),
            ("红色", "red"),
            ("绿色", "green"),
            ("黑白", "black and white"),
            ("逆光", "backlight"),
            ("剪影", "silhouette"),
            ("光影", "light and shadow"),
            ("柔光", "soft light"),
            ("自然光", "natural light"),

            // ── 物体 ──
            ("车", "car"),
            ("汽车", "car"),
            ("建筑", "building"),
            ("楼", "building"),
            ("动物", "animal"),
            ("树", "tree"),
            ("水", "water"),
            ("食物", "food"),
            ("手机", "phone"),
            ("电脑", "computer"),
            ("飞机", "airplane"),
            ("船", "boat"),
            ("桥", "bridge"),
            ("门", "door"),
            ("窗", "window"),
            ("路", "road"),
            ("马路", "road"),
            ("灯", "light"),
            ("书", "book"),
            ("花瓶", "vase"),
            ("杯子", "cup"),
            ("椅子", "chair"),
            ("桌子", "table"),
            ("镜子", "mirror"),
            ("钟", "clock"),
            ("伞", "umbrella"),
            ("帽子", "hat"),
            ("眼镜", "glasses"),
            ("相机", "camera"),
            ("烟花", "fireworks"),
            ("蜡烛", "candle"),
            ("气球", "balloon"),
            ("旗帜", "flag"),
            ("猫", "cat"),
            ("狗", "dog"),
            ("鸟", "bird"),
            ("鱼", "fish"),
            ("马", "horse"),
            ("蝴蝶", "butterfly"),

            // ── 场景与地点 ──
            ("城市", "city"),
            ("乡村", "countryside"),
            ("室内", "indoor"),
            ("室外", "outdoor"),
            ("夜晚", "night"),
            ("白天", "daytime"),
            ("街道", "street"),
            ("公园", "park"),
            ("广场", "square"),
            ("商场", "mall"),
            ("餐厅", "restaurant"),
            ("咖啡馆", "cafe"),
            ("学校", "school"),
            ("医院", "hospital"),
            ("机场", "airport"),
            ("火车站", "train station"),
            ("教堂", "church"),
            ("寺庙", "temple"),
            ("博物馆", "museum"),
            ("图书馆", "library"),
            ("办公室", "office"),
            ("工厂", "factory"),
            ("农场", "farm"),
            ("海边", "seaside"),
            ("山顶", "mountaintop"),
            ("地铁", "subway"),
            ("码头", "dock"),
            ("港口", "harbor"),

            // ── 天气与时间 ──
            ("晴天", "sunny"),
            ("阴天", "cloudy"),
            ("雨天", "rainy"),
            ("雪天", "snowy"),
            ("早晨", "morning"),
            ("中午", "noon"),
            ("下午", "afternoon"),
            ("傍晚", "dusk"),
            ("黄昏", "twilight"),
            ("黎明", "dawn"),
            ("午夜", "midnight"),
            ("春天", "spring"),
            ("夏天", "summer"),
            ("秋天", "autumn"),
            ("冬天", "winter"),
        ]
        // swiftlint:enable line_length
    }
}
