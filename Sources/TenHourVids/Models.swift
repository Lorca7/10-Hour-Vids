import Foundation

enum Limits {
    static let minDuration: Double = 60            // 1 minute
    static let maxDuration: Double = 10 * 3600     // 10 hours
    static let minClipLength: Double = 0.1
    static let minLoopRegion: Double = 0.5
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Video

enum FitMode: String, Codable, CaseIterable, Identifiable {
    case fit, fill, blur
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Fit – show the whole photo"
        case .fill: return "Fill – crop to fill the frame"
        case .blur: return "Fit on a blurred copy"
        }
    }
}

struct RGBColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    static let black = RGBColor(r: 0, g: 0, b: 0)
}

struct VideoSettings: Codable, Equatable {
    var duration: Double = 3600
    var fitMode: FitMode = .fit
    var background: RGBColor = .black
}

// MARK: - Audio clips

enum ClipKind: String, Codable {
    case audio, video
}

struct ClipSegment: Equatable {
    let sourceStart: Double
    let duration: Double
    let timelineStart: Double
}

/// One audio or video clip on the timeline.
///
/// The clip plays the source file from `inPoint` onwards. When `loop` is on, the region
/// `inPoint ..< outPoint` repeats until the clip's `length` is filled, starting `offset`
/// seconds into that region (this is how a looped clip can be split or trimmed from the left).
struct MediaClip: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var url: URL
    var name: String
    var sourceDuration: Double
    var inPoint: Double
    var outPoint: Double
    var offset: Double = 0
    var start: Double
    var length: Double
    var lane: Int
    var volume: Double = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var loop: Bool = false
    /// Stored only for video clips, so projects saved before video support still open.
    var mediaKind: ClipKind?

    var kind: ClipKind {
        get { mediaKind ?? .audio }
        set { mediaKind = newValue == .audio ? nil : newValue }
    }

    var end: Double { start + length }
    var region: Double { max(outPoint - inPoint, 0.001) }

    static func wrap(_ value: Double, _ modulus: Double) -> Double {
        guard modulus > 0 else { return 0 }
        let r = value.truncatingRemainder(dividingBy: modulus)
        return r < 0 ? r + modulus : r
    }

    /// Position in the source file that plays at timeline time `t`.
    func sourceTime(at t: Double) -> Double {
        let local = t - start
        if !loop { return inPoint + local }
        return inPoint + MediaClip.wrap(offset + local, region)
    }

    /// Volume (0...1) at timeline time `t`, including fades.
    func gain(at t: Double) -> Double {
        let local = t - start
        var g = volume
        if fadeIn > 0, local < fadeIn { g *= max(0, local / fadeIn) }
        if fadeOut > 0, local > length - fadeOut { g *= max(0, (length - local) / fadeOut) }
        return g
    }

    /// The pieces of source audio that make up this clip, in timeline order.
    func segments() -> [ClipSegment] {
        if !loop || region < 0.25 {
            return [ClipSegment(sourceStart: inPoint, duration: length, timelineStart: start)]
        }
        var result: [ClipSegment] = []
        var remaining = length
        var t = start
        var src = inPoint + MediaClip.wrap(offset, region)
        while remaining > 0.0005 {
            var d = min(outPoint - src, remaining)
            if d <= 0.0005 { src = inPoint; d = min(region, remaining) }
            result.append(ClipSegment(sourceStart: src, duration: d, timelineStart: t))
            t += d
            remaining -= d
            src = inPoint
        }
        return result
    }

    /// Keeps every field inside its valid range.
    mutating func normalize() {
        let minLen = Limits.minClipLength
        sourceDuration = max(sourceDuration, minLen)
        start = max(0, start)
        lane = max(0, lane)
        inPoint = min(max(0, inPoint), sourceDuration - minLen)
        if loop {
            outPoint = min(max(outPoint, inPoint + Limits.minLoopRegion), sourceDuration)
            length = min(max(length, minLen), Limits.maxDuration)
            offset = MediaClip.wrap(offset, region)
        } else {
            offset = 0
            length = min(max(length, minLen), sourceDuration - inPoint)
            outPoint = inPoint + length
        }
        volume = min(max(volume, 0), 1)
        fadeIn = max(0, fadeIn)
        fadeOut = max(0, fadeOut)
        if fadeIn + fadeOut > length {
            let scale = length / (fadeIn + fadeOut)
            fadeIn *= scale
            fadeOut *= scale
        }
    }

    /// Splits the clip at timeline time `t`, returning the left and right halves.
    func split(at t: Double) -> (MediaClip, MediaClip)? {
        guard t > start + Limits.minClipLength, t < end - Limits.minClipLength else { return nil }
        let o = t - start
        var a = self
        var b = self
        b.id = UUID()
        a.length = o
        a.fadeOut = 0
        b.start = t
        b.length = length - o
        b.fadeIn = 0
        if loop {
            b.offset = MediaClip.wrap(offset + o, region)
        } else {
            a.outPoint = inPoint + o
            b.inPoint = inPoint + o
        }
        a.normalize()
        b.normalize()
        return (a, b)
    }

    func overlaps(_ other: MediaClip) -> Bool {
        kind == other.kind && lane == other.lane && start < other.end - 0.0001 && other.start < end - 0.0001
    }
}

struct Project: Codable, Equatable {
    var version = 1
    var imageURL: URL?
    var video = VideoSettings()
    var clips: [MediaClip] = []

    var mediaEnd: Double { clips.map(\.end).max() ?? 0 }
}

/// A stretch of the finished video showing either the photo (`clipID == nil`) or one video clip.
struct VideoSpan: Equatable {
    var start: Double
    var end: Double
    var clipID: UUID?
}

extension Project {
    var hasVideoClips: Bool { clips.contains { $0.kind == .video } }

    /// The video clip seen at time `t`: the highest lane wins, then the clip added last.
    func topVideoClip(at t: Double) -> MediaClip? {
        guard t >= 0, t < video.duration else { return nil }
        var best: (lane: Int, index: Int)?
        var result: MediaClip?
        for (i, c) in clips.enumerated() where c.kind == .video && c.start <= t && t < c.end {
            if best == nil || (c.lane, i) > (best!.lane, best!.index) {
                best = (c.lane, i)
                result = c
            }
        }
        return result
    }

    /// The whole video split into stretches of photo and visible video clips, in order.
    func videoSpans() -> [VideoSpan] {
        let duration = video.duration
        var bounds: Set<Double> = [0, duration]
        for c in clips where c.kind == .video {
            for b in [c.start, c.end] where b > 0 && b < duration { bounds.insert(b) }
        }
        let sorted = bounds.sorted()
        var spans: [VideoSpan] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            guard b - a > 1e-9 else { continue }
            let id = topVideoClip(at: (a + b) / 2)?.id
            if let last = spans.last, last.clipID == id {
                spans[spans.count - 1].end = b
            } else {
                spans.append(VideoSpan(start: a, end: b, clipID: id))
            }
        }
        return spans
    }

    /// Seconds of the finished video that show a video clip rather than the photo.
    var videoClipSeconds: Double {
        videoSpans().filter { $0.clipID != nil }.reduce(0) { $0 + $1.end - $1.start }
    }
}

// MARK: - Export

enum ExportResolution: String, CaseIterable, Identifiable, Codable {
    case hd720, hd1080, qhd1440, uhd2160
    var id: String { rawValue }
    var width: Int {
        switch self {
        case .hd720: return 1280
        case .hd1080: return 1920
        case .qhd1440: return 2560
        case .uhd2160: return 3840
        }
    }
    var height: Int { width * 9 / 16 }
    var label: String {
        switch self {
        case .hd720: return "720p HD (1280 × 720)"
        case .hd1080: return "1080p Full HD (1920 × 1080)"
        case .qhd1440: return "1440p (2560 × 1440)"
        case .uhd2160: return "4K (3840 × 2160)"
        }
    }
    /// Average bit rate for the encoder (YouTube's recommended upload rates).
    var bitrate: Int {
        switch self {
        case .hd720: return 5_000_000
        case .hd1080: return 8_000_000
        case .qhd1440: return 16_000_000
        case .uhd2160: return 40_000_000
        }
    }
}

struct ExportSettings: Equatable {
    var resolution: ExportResolution = .hd1080
    var fps: Int = 30
    var audioBitrate: Int = 256_000
    /// Seconds between full keyframes. The picture never changes, so long gaps keep files small.
    static let keyframeInterval = 10

    func estimatedBytes(duration: Double, hasAudio: Bool, videoSeconds: Double = 0) -> Double {
        let keyframeBytes = Double(resolution.width * resolution.height) * 0.3
        let photoSeconds = max(0, duration - videoSeconds)
        let video = keyframeBytes * photoSeconds / Double(Self.keyframeInterval) + photoSeconds * Double(fps) * 40
            + videoSeconds * Double(resolution.bitrate) / 8
        let audio = hasAudio ? Double(audioBitrate) / 8 * duration : 0
        return video + audio
    }
}

// MARK: - Time formatting

enum Timecode {
    static func format(_ seconds: Double, tenths: Bool = false) -> String {
        let s = max(0, seconds.isFinite ? seconds : 0)
        if tenths {
            let t = Int((s * 10).rounded())
            return String(format: "%d:%02d:%02d.%d", t / 36000, (t % 36000) / 600, (t % 600) / 10, t % 10)
        }
        let t = Int(s.rounded())
        return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    /// Accepts "1:02:03.5", "12:30", or plain seconds such as "90".
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part.trimmingCharacters(in: .whitespaces)), v >= 0, v.isFinite else { return nil }
            total = total * 60 + v
        }
        return total
    }

    static func byteCount(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
