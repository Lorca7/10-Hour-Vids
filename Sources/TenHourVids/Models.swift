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

struct ClipSegment: Equatable {
    let sourceStart: Double
    let duration: Double
    let timelineStart: Double
}

/// One piece of audio on the timeline.
///
/// The clip plays the source file from `inPoint` onwards. When `loop` is on, the region
/// `inPoint ..< outPoint` repeats until the clip's `length` is filled, starting `offset`
/// seconds into that region (this is how a looped clip can be split or trimmed from the left).
struct AudioClip: Codable, Identifiable, Equatable {
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
        return inPoint + AudioClip.wrap(offset + local, region)
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
        var src = inPoint + AudioClip.wrap(offset, region)
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
            offset = AudioClip.wrap(offset, region)
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
    func split(at t: Double) -> (AudioClip, AudioClip)? {
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
            b.offset = AudioClip.wrap(offset + o, region)
        } else {
            a.outPoint = inPoint + o
            b.inPoint = inPoint + o
        }
        a.normalize()
        b.normalize()
        return (a, b)
    }

    func overlaps(_ other: AudioClip) -> Bool {
        lane == other.lane && start < other.end - 0.0001 && other.start < end - 0.0001
    }
}

struct Project: Codable, Equatable {
    var version = 1
    var imageURL: URL?
    var video = VideoSettings()
    var clips: [AudioClip] = []

    var audioEnd: Double { clips.map(\.end).max() ?? 0 }
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
    /// Bit budget handed to the encoder for the still picture.
    var bitrate: Int {
        switch self {
        case .hd720: return 6_000_000
        case .hd1080: return 12_000_000
        case .qhd1440: return 20_000_000
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

    func estimatedBytes(duration: Double, hasAudio: Bool) -> Double {
        let keyframeBytes = Double(resolution.width * resolution.height) * 0.3
        let video = keyframeBytes * duration / Double(Self.keyframeInterval) + duration * Double(fps) * 40
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
