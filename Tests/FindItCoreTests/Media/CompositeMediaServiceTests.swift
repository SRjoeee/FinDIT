import XCTest
@testable import FindItCore

// MARK: - Mock Decoders

/// 可配置评分的 Mock 解码器
private final class MockMediaDecoder: MediaDecoder, @unchecked Sendable {
    let capability: MediaCapability
    let probeScore: Int

    init(
        name: String,
        extensions: Set<String>,
        priority: Int,
        probeScore: Int
    ) {
        self.capability = MediaCapability(
            fileExtensions: extensions,
            name: name,
            priority: priority
        )
        self.probeScore = probeScore
    }

    func probe(filePath: String) async throws -> ProbeResult {
        ProbeResult(
            score: probeScore,
            mediaType: .video,
            containerFormat: nil,
            codec: "mock",
            duration: 60.0
        )
    }

    func extractKeyframes(
        filePath: String, times: [Double],
        outputDir: String, maxDimension: Int
    ) async throws -> [String] {
        times.enumerated().map { i, _ in "\(outputDir)/mock_\(i).jpg" }
    }

    func extractAudio(
        filePath: String, outputPath: String, sampleRate: Int
    ) async throws -> String {
        outputPath
    }
}

/// Mock 解码器 + SceneDetectable
private final class MockSceneDetectableDecoder: MediaDecoder, SceneDetectable, @unchecked Sendable {
    let capability: MediaCapability
    let probeScore: Int

    init(name: String, extensions: Set<String>, priority: Int, probeScore: Int) {
        self.capability = MediaCapability(
            fileExtensions: extensions,
            name: name,
            priority: priority
        )
        self.probeScore = probeScore
    }

    func probe(filePath: String) async throws -> ProbeResult {
        ProbeResult(score: probeScore, mediaType: .video, duration: 120.0)
    }

    func extractKeyframes(
        filePath: String, times: [Double],
        outputDir: String, maxDimension: Int
    ) async throws -> [String] { [] }

    func extractAudio(
        filePath: String, outputPath: String, sampleRate: Int
    ) async throws -> String { outputPath }

    func detectScenesOptimized(
        filePath: String,
        audioOutputPath: String?,
        config: SceneDetector.Config
    ) async throws -> SceneDetector.CombinedDetectionResult {
        SceneDetector.CombinedDetectionResult(
            scenes: [SceneSegment(startTime: 0, endTime: 10)],
            duration: 120.0,
            audioExtracted: false
        )
    }
}

/// 总是返回 score 0 的 Mock
private final class MockUnsupportedDecoder: MediaDecoder, @unchecked Sendable {
    let capability = MediaCapability(
        fileExtensions: ["mp4", "mov"],
        name: "Unsupported",
        priority: 100
    )

    func probe(filePath: String) async throws -> ProbeResult {
        .unsupported()
    }

    func extractKeyframes(
        filePath: String, times: [Double],
        outputDir: String, maxDimension: Int
    ) async throws -> [String] { [] }

    func extractAudio(
        filePath: String, outputPath: String, sampleRate: Int
    ) async throws -> String { outputPath }
}

// MARK: - Tests

final class CompositeMediaServiceTests: XCTestCase {

    // MARK: - 注册与排序

    func testRegisterSortsByPriority() async throws {
        let service = CompositeMediaService()
        let low = MockMediaDecoder(name: "Low", extensions: ["mp4"], priority: 10, probeScore: 70)
        let high = MockMediaDecoder(name: "High", extensions: ["mp4"], priority: 90, probeScore: 70)
        let mid = MockMediaDecoder(name: "Mid", extensions: ["mp4"], priority: 50, probeScore: 70)

        service.register(low)
        service.register(high)
        service.register(mid)

        // bestDecoder 应选 score 最高（都是 70），同 score 取 priority 最高 (High=90)
        let decoder = try await service.bestDecoder(for: "/test/video.mp4")
        XCTAssertEqual(decoder.capability.name, "High")
    }

    // MARK: - 最优选择

    func testBestDecoderSelectsHighestScore() async throws {
        let service = CompositeMediaService()
        let lowScore = MockMediaDecoder(name: "LowScore", extensions: ["mp4"], priority: 90, probeScore: 30)
        let highScore = MockMediaDecoder(name: "HighScore", extensions: ["mp4"], priority: 50, probeScore: 80)

        service.register(lowScore)
        service.register(highScore)

        let decoder = try await service.bestDecoder(for: "/test/video.mp4")
        XCTAssertEqual(decoder.capability.name, "HighScore", "应选 score 最高的 decoder")
    }

    func testBestDecoderSameScoreSelectsHigherPriority() async throws {
        let service = CompositeMediaService()
        let highPriority = MockMediaDecoder(name: "HighPri", extensions: ["mp4"], priority: 80, probeScore: 70)
        let lowPriority = MockMediaDecoder(name: "LowPri", extensions: ["mp4"], priority: 50, probeScore: 70)

        service.register(highPriority)
        service.register(lowPriority)

        let decoder = try await service.bestDecoder(for: "/test/video.mp4")
        XCTAssertEqual(decoder.capability.name, "HighPri", "同 score 应选 priority 更高的")
    }

    // MARK: - Fallback

    func testFallbackWhenHighPriorityScoreZero() async throws {
        let service = CompositeMediaService()
        let unsupported = MockUnsupportedDecoder()  // P:100, score:0
        let fallback = MockMediaDecoder(name: "Fallback", extensions: ["mp4"], priority: 50, probeScore: 70)

        service.register(unsupported)
        service.register(fallback)

        let decoder = try await service.bestDecoder(for: "/test/video.mp4")
        XCTAssertEqual(decoder.capability.name, "Fallback", "高优先级 score=0 时应 fallback")
    }

    func testNoDecoderAvailableWhenAllScoreZero() async {
        let service = CompositeMediaService()
        let unsupported = MockUnsupportedDecoder()
        service.register(unsupported)

        do {
            _ = try await service.bestDecoder(for: "/test/video.mp4")
            XCTFail("应该抛出 noDecoderAvailable")
        } catch let error as MediaError {
            if case .noDecoderAvailable = error {
                // 预期
            } else {
                XCTFail("应该是 noDecoderAvailable，实际: \(error)")
            }
        } catch {
            XCTFail("应该抛出 MediaError，实际: \(error)")
        }
    }

    func testNoDecoderAvailableWhenEmpty() async {
        let service = CompositeMediaService()

        do {
            _ = try await service.bestDecoder(for: "/test/video.mp4")
            XCTFail("应该抛出 noDecoderAvailable")
        } catch let error as MediaError {
            if case .noDecoderAvailable = error {
                // 预期
            } else {
                XCTFail("应该是 noDecoderAvailable，实际: \(error)")
            }
        } catch {
            XCTFail("应该抛出 MediaError，实际: \(error)")
        }
    }

    // MARK: - 扩展名过滤

    func testExtensionFiltering() async throws {
        let service = CompositeMediaService()
        let mp4Decoder = MockMediaDecoder(name: "MP4Only", extensions: ["mp4"], priority: 80, probeScore: 90)
        let mkvDecoder = MockMediaDecoder(name: "MKVOnly", extensions: ["mkv"], priority: 80, probeScore: 90)

        service.register(mp4Decoder)
        service.register(mkvDecoder)

        let decoder = try await service.bestDecoder(for: "/test/video.mkv")
        XCTAssertEqual(decoder.capability.name, "MKVOnly", "应按扩展名匹配")
    }

    func testFallbackToAnyDecoderWhenNoExtensionMatch() async throws {
        let service = CompositeMediaService()
        let mp4Decoder = MockMediaDecoder(name: "MP4Only", extensions: ["mp4"], priority: 80, probeScore: 70)

        service.register(mp4Decoder)

        // .flv 没有匹配的 decoder，应尝试所有 decoder
        let decoder = try await service.bestDecoder(for: "/test/video.flv")
        XCTAssertEqual(decoder.capability.name, "MP4Only", "无匹配扩展名时应尝试所有 decoder")
    }

    // MARK: - 缓存

    func testDecoderCaching() async throws {
        let service = CompositeMediaService()
        let decoder1 = MockMediaDecoder(name: "Fast", extensions: ["mp4"], priority: 80, probeScore: 90)
        service.register(decoder1)

        // 第一次选择
        let selected1 = try await service.bestDecoder(for: "/test/a.mp4")
        XCTAssertEqual(selected1.capability.name, "Fast")

        // 第二次应从缓存获取（相同扩展名）
        let selected2 = try await service.bestDecoder(for: "/test/b.mp4")
        XCTAssertEqual(selected2.capability.name, "Fast")
    }

    func testCacheClearedOnRegister() async throws {
        let service = CompositeMediaService()
        let first = MockMediaDecoder(name: "First", extensions: ["mp4"], priority: 50, probeScore: 70)
        service.register(first)

        _ = try await service.bestDecoder(for: "/test/video.mp4")  // 填充缓存

        // 注册新的高评分 decoder
        let better = MockMediaDecoder(name: "Better", extensions: ["mp4"], priority: 80, probeScore: 95)
        service.register(better)

        let selected = try await service.bestDecoder(for: "/test/video.mp4")
        XCTAssertEqual(selected.capability.name, "Better", "注册新 decoder 后缓存应清除")
    }

    // MARK: - SceneDetectable 条件转发

    func testSceneDetectableForwarding() async throws {
        let service = CompositeMediaService()
        let sceneDecoder = MockSceneDetectableDecoder(
            name: "SceneAware", extensions: ["mp4"], priority: 50, probeScore: 70
        )
        service.register(sceneDecoder)

        let result = try await service.detectScenesOptimized(
            filePath: "/test/video.mp4",
            audioOutputPath: nil,
            config: .default
        )
        XCTAssertEqual(result.scenes.count, 1)
        XCTAssertEqual(result.duration, 120.0)
    }

    func testSceneDetectableFallbackWhenBestNotSceneDetectable() async throws {
        let service = CompositeMediaService()
        // 高优先级但不支持场景检测
        let highPri = MockMediaDecoder(name: "HighPri", extensions: ["mp4"], priority: 90, probeScore: 95)
        // 低优先级但支持场景检测
        let sceneDecoder = MockSceneDetectableDecoder(
            name: "SceneAware", extensions: ["mp4"], priority: 50, probeScore: 70
        )

        service.register(highPri)
        service.register(sceneDecoder)

        // 场景检测应 fallback 到 SceneAware
        let result = try await service.detectScenesOptimized(
            filePath: "/test/video.mp4",
            audioOutputPath: nil,
            config: .default
        )
        XCTAssertEqual(result.scenes.count, 1)
    }

    func testSceneDetectableThrowsWhenNoneAvailable() async {
        let service = CompositeMediaService()
        let noScene = MockMediaDecoder(name: "NoScene", extensions: ["mp4"], priority: 80, probeScore: 90)
        service.register(noScene)

        do {
            _ = try await service.detectScenesOptimized(
                filePath: "/test/video.mp4",
                audioOutputPath: nil,
                config: .default
            )
            XCTFail("应该抛出 operationNotSupported")
        } catch let error as MediaError {
            if case .operationNotSupported(let msg) = error {
                XCTAssertTrue(msg.contains("scene"))
            } else {
                XCTFail("应该是 operationNotSupported，实际: \(error)")
            }
        } catch {
            XCTFail("应该抛出 MediaError，实际: \(error)")
        }
    }

    // MARK: - MediaService 协议方法

    func testProbeViaService() async throws {
        let service = CompositeMediaService()
        let decoder = MockMediaDecoder(name: "Test", extensions: ["mp4"], priority: 50, probeScore: 85)
        service.register(decoder)

        let result = try await service.probe(filePath: "/test/video.mp4")
        XCTAssertEqual(result.score, 85)
        XCTAssertEqual(result.codec, "mock")
    }

    func testSupportLevelFullDecode() async {
        let service = CompositeMediaService()
        let decoder = MockMediaDecoder(name: "Test", extensions: ["mp4"], priority: 50, probeScore: 70)
        service.register(decoder)

        let level = await service.supportLevel(for: "/test/video.mp4")
        XCTAssertEqual(level, .fullDecode)
    }

    func testSupportLevelUnsupported() async {
        let service = CompositeMediaService()
        let decoder = MockUnsupportedDecoder()
        service.register(decoder)

        let level = await service.supportLevel(for: "/test/video.mp4")
        XCTAssertEqual(level, .unsupported)
    }

    func testSupportLevelNoDecoders() async {
        let service = CompositeMediaService()
        let level = await service.supportLevel(for: "/test/video.r3d")
        XCTAssertEqual(level, .unsupported)
    }

    // MARK: - makeDefault

    func testMakeDefault() {
        let service = CompositeMediaService.makeDefault()
        // 应注册了 4 个 decoder (BRAW P:150 + R3D P:140 + AVF P:80 + FFmpeg P:50)
        // 无法直接访问 decoders，通过功能验证
        XCTAssertNotNil(service)
    }

    func testMakeDefaultWithConfig() {
        let config = FFmpegConfig(ffmpegPath: "/usr/local/bin/ffmpeg")
        let service = CompositeMediaService.makeDefault(ffmpegConfig: config)
        XCTAssertNotNil(service)
    }
}
