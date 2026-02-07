import SwiftUI
import AppKit

/// 缩略图视图
///
/// 异步加载磁盘上的缩略图文件，显示 16:9 裁切的图片。
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

    /// 在后台线程加载图片，避免阻塞主线程
    private func loadImage(from path: String) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOfFile: path)
                continuation.resume(returning: img)
            }
        }
    }
}
