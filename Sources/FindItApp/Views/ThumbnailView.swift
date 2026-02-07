import SwiftUI
import AppKit

/// 缩略图视图
///
/// 异步加载磁盘上的缩略图文件，显示 16:9 裁切的图片。
/// 使用 CGImageSource 下采样（512px → 300px），全局 NSCache 缓存。
/// 无缩略图时显示占位图标。
struct ThumbnailView: View {
    let path: String?
    let aspectRatio: CGFloat = 16.0 / 9.0

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fill)
            } else {
                // 占位图
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(aspectRatio, contentMode: .fill)
                    .overlay {
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            guard let path else {
                image = nil
                return
            }
            image = await loadImage(from: path)
        }
    }

    /// 加载图片：先查缓存，miss 时后台下采样加载
    private func loadImage(from path: String) async -> NSImage? {
        // 缓存命中
        if let cached = ThumbnailCache.shared.get(path) {
            return cached
        }

        // 后台下采样加载
        let loaded = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = Self.downsampledImage(at: path, maxPixelSize: 300)
                continuation.resume(returning: img)
            }
        }

        // 写入缓存
        if let loaded {
            ThumbnailCache.shared.set(path, image: loaded)
        }
        return loaded
    }

    /// CGImageSource 下采样加载
    ///
    /// 利用 `kCGImageSourceThumbnailMaxPixelSize` 在解码阶段就限制像素，
    /// 避免先加载全尺寸 bitmap 再缩放。512×288 → 300×169，内存减少约 50%。
    private static func downsampledImage(at path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            // 回退到普通加载
            return NSImage(contentsOfFile: path)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

// MARK: - ThumbnailCache

/// 全局缩略图缓存
///
/// 使用 NSCache 自动 LRU 淘汰，内存压力时系统自动回收。
/// countLimit=200 限制缓存条数，每张约 150KB（300×169×4），
/// 峰值约 30MB。
private final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    func get(_ path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    func set(_ path: String, image: NSImage) {
        cache.setObject(image, forKey: path as NSString)
    }
}
