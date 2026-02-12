import Foundation

/// SMPTE Timecode 表示
///
/// 支持 non-drop frame 和 drop frame（29.97fps）两种模式。
/// Drop frame 规则：每分钟跳过 :00 和 :01 帧，第 10 分钟除外。
public struct Timecode: CustomStringConvertible, Equatable, Sendable {

    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int
    public let fps: Double
    public let dropFrame: Bool

    // MARK: - Init from seconds

    /// 从秒数创建 timecode
    ///
    /// - Parameters:
    ///   - seconds: 时间（秒），负数视为 0
    ///   - fps: 帧率（默认 24）
    ///   - dropFrame: 是否使用 drop frame（仅 29.97fps 有效）
    public init(seconds: Double, fps: Double = 24, dropFrame: Bool = false) {
        let effectiveFps = fps
        let effectiveDropFrame = dropFrame && Timecode.isDropFrameRate(fps)
        let clamped = max(0, seconds)

        self.fps = effectiveFps
        self.dropFrame = effectiveDropFrame

        let nominalFps = Int(round(effectiveFps))

        if effectiveDropFrame {
            // Drop-frame timecode for 29.97fps
            // Total frames at actual rate
            let totalFrames = Int(round(clamped * effectiveFps))

            // Drop-frame adjustment: 2 frames dropped per minute, except every 10th minute
            // D = dropFrames per minute = 2 for 29.97
            let d = 2
            let framesPerMin = nominalFps * 60 - d           // 1798
            let framesPer10Min = framesPerMin * 10 + d       // 17982

            let tenMinBlocks = totalFrames / framesPer10Min
            let remainder = totalFrames % framesPer10Min

            // Frames within the 10-min block after first minute (which has no drop)
            var adjustedMinutes: Int
            if remainder < nominalFps * 60 {
                // Still in the first minute of the 10-min block (no drop)
                adjustedMinutes = 0
            } else {
                adjustedMinutes = (remainder - nominalFps * 60) / framesPerMin + 1
            }

            let totalMinutes = tenMinBlocks * 10 + adjustedMinutes

            // Now compute what frame number we'd be at without drops
            let droppedFrames = d * (totalMinutes - totalMinutes / 10)
            let adjustedFrameCount = totalFrames + droppedFrames

            let f = adjustedFrameCount % nominalFps
            let s = (adjustedFrameCount / nominalFps) % 60
            let m = (adjustedFrameCount / (nominalFps * 60)) % 60
            let h = adjustedFrameCount / (nominalFps * 3600)

            self.hours = h
            self.minutes = m
            self.seconds = s
            self.frames = f
        } else {
            // Non-drop frame
            let totalFrames = Int(round(clamped * effectiveFps))
            let f = totalFrames % nominalFps
            let totalSec = totalFrames / nominalFps
            let s = totalSec % 60
            let m = (totalSec / 60) % 60
            let h = totalSec / 3600

            self.hours = h
            self.minutes = m
            self.seconds = s
            self.frames = f
        }
    }

    // MARK: - Init from components

    /// 从时/分/秒/帧创建 timecode
    public init(hours: Int, minutes: Int, seconds: Int, frames: Int,
                fps: Double = 24, dropFrame: Bool = false) {
        self.hours = max(0, hours)
        self.minutes = max(0, min(59, minutes))
        self.seconds = max(0, min(59, seconds))
        self.frames = max(0, min(Int(round(fps)) - 1, frames))
        self.fps = fps
        self.dropFrame = dropFrame && Timecode.isDropFrameRate(fps)
    }

    // MARK: - Parse from string

    /// 从 timecode 字符串解析
    ///
    /// 支持 "HH:MM:SS:FF" (non-drop) 和 "HH:MM:SS;FF" (drop-frame)
    public init?(string: String, fps: Double = 24) {
        // Accept both : and ; as separators
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == ";" })
        guard parts.count == 4,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              let s = Int(parts[2]),
              let f = Int(parts[3]) else {
            return nil
        }

        let isDrop = string.contains(";")
        self.init(hours: h, minutes: m, seconds: s, frames: f,
                  fps: fps, dropFrame: isDrop)
    }

    // MARK: - Output

    /// HH:MM:SS:FF (non-drop) 或 HH:MM:SS;FF (drop-frame)
    public var description: String {
        let sep = dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d\(sep)%02d", hours, minutes, seconds, frames)
    }

    /// 转换回总秒数
    public var totalSeconds: Double {
        let nominalFps = Int(round(fps))

        if dropFrame {
            let d = 2
            // Convert HH:MM:SS:FF back to frame count, removing dropped frames
            let totalMinutes = hours * 60 + minutes
            let droppedFrames = d * (totalMinutes - totalMinutes / 10)
            let frameCount = hours * 3600 * nominalFps
                + minutes * 60 * nominalFps
                + seconds * nominalFps
                + frames
                - droppedFrames
            return Double(frameCount) / fps
        } else {
            let frameCount = hours * 3600 * nominalFps
                + minutes * 60 * nominalFps
                + seconds * nominalFps
                + frames
            return Double(frameCount) / fps
        }
    }

    /// 总帧数
    public var totalFrames: Int {
        let nominalFps = Int(round(fps))
        if dropFrame {
            let d = 2
            let totalMinutes = hours * 60 + minutes
            let droppedFrames = d * (totalMinutes - totalMinutes / 10)
            return hours * 3600 * nominalFps
                + minutes * 60 * nominalFps
                + seconds * nominalFps
                + frames
                - droppedFrames
        } else {
            return hours * 3600 * nominalFps
                + minutes * 60 * nominalFps
                + seconds * nominalFps
                + frames
        }
    }

    // MARK: - Helpers

    /// 是否为 drop-frame 兼容帧率（29.97, 59.94）
    public static func isDropFrameRate(_ fps: Double) -> Bool {
        let rounded = round(fps * 100) / 100
        return rounded == 29.97 || rounded == 59.94
    }
}
