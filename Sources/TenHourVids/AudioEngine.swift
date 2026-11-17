import Foundation
import AVFoundation
import AppKit

/// The timeline's clips assembled into one composition: the audio of every clip mixed, and
/// (for preview playback) the visible video clips.
struct BuiltAudio {
    let composition: AVMutableComposition
    let audioMix: AVMutableAudioMix
    /// Seconds of audio, already cut at the video's end.
    let duration: Double
    /// Set when the composition also has a video track (preview only).
    var videoComposition: AVMutableVideoComposition?
}

enum CompositionBuilder {
    static let timescale: CMTimeScale = 48_000
    static func cm(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

    /// Loads each file once per build. Tracks only weakly reference their asset, so the assets are kept here.
    final class Sources {
        private var assets: [URL: AVURLAsset] = [:]
        private var tracks: [String: (track: AVAssetTrack, range: CMTimeRange)?] = [:]

        func track(_ url: URL, _ type: AVMediaType) async throws -> (track: AVAssetTrack, range: CMTimeRange)? {
            let key = "\(type.rawValue)|\(url.absoluteString)"
            if let cached = tracks[key] { return cached }
            let asset = assets[url] ?? AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            assets[url] = asset
            var result: (track: AVAssetTrack, range: CMTimeRange)?
            if let t = try await asset.loadTracks(withMediaType: type).first {
                result = (t, try await t.load(.timeRange))
            }
            tracks[key] = result
            return result
        }
    }

    /// Mixes the audio of all clips (audio clips, and the sound of video clips).
    /// `window` limits the build to part of the timeline, which keeps preview builds quick.
    static func build(clips: [MediaClip], limit: Double, window: ClosedRange<Double>? = nil,
                      sources: Sources = Sources(), into existing: AVMutableComposition? = nil) async throws -> BuiltAudio {
        let composition = existing ?? AVMutableComposition()
        var params: [AVMutableAudioMixInputParameters] = []
        var maxEnd = 0.0
        let lower = window?.lowerBound ?? 0
        let upper = min(window?.upperBound ?? limit, limit)

        for clip in clips.sorted(by: { $0.start < $1.start }) {
            let clipEnd = min(clip.end, upper)
            guard clipEnd - max(clip.start, lower) > 0.01 else { continue }
            guard let source = try await sources.track(clip.url, .audio) else {
                if clip.kind == .video { continue }  // a silent video is fine
                throw AppError("“\(clip.name)” has no readable audio.")
            }
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }

            var cursor: CMTime?
            let endTime = cm(clipEnd)
            for segment in clip.segments() {
                let segEnd = segment.timelineStart + segment.duration
                if segEnd <= lower { continue }
                let s0 = max(segment.timelineStart, lower)
                if s0 >= clipEnd { break }
                if cursor == nil {
                    cursor = cm(s0)
                    if s0 > 0 { track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: cursor!)) }
                }
                guard let at = cursor else { break }
                let srcStart = cm(segment.sourceStart + (s0 - segment.timelineStart))
                var duration = cm(min(segEnd, clipEnd)) - at
                if at + duration > endTime { duration = endTime - at }
                if srcStart + duration > source.range.end { duration = source.range.end - srcStart }
                if duration.seconds <= 0.001 { continue }
                try track.insertTimeRange(CMTimeRange(start: srcStart, duration: duration), of: source.track, at: at)
                cursor = at + duration
            }
            guard let end = cursor else {
                composition.removeTrack(track)
                continue
            }

            let p = AVMutableAudioMixInputParameters(track: track)
            let volume = Float(min(max(clip.volume, 0), 1))
            p.setVolume(volume, at: .zero)
            if clip.fadeIn > 0.01 {
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                timeRange: CMTimeRange(start: cm(clip.start), duration: cm(clip.fadeIn)))
            }
            if clip.fadeOut > 0.01 {
                p.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                timeRange: CMTimeRange(start: cm(clip.end - clip.fadeOut), duration: cm(clip.fadeOut)))
            }
            params.append(p)
            maxEnd = max(maxEnd, end.seconds)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return BuiltAudio(composition: composition, audioMix: mix, duration: min(maxEnd, limit))
    }

    /// Audio plus the visible video clips for preview playback, rendered at `renderSize`.
    static func buildPreview(project: Project, window: ClosedRange<Double>, renderSize: CGSize) async throws -> BuiltAudio {
        let sources = Sources()
        let composition = AVMutableComposition()
        let limit = project.video.duration
        let upper = min(window.upperBound, limit)
        var videoComposition: AVMutableVideoComposition?

        let byID = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0) })
        let spans = project.videoSpans().filter { $0.clipID != nil && $0.end > window.lowerBound && $0.start < upper }
        if !spans.isEmpty, let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            var cursor: CMTime?
            for span in spans {
                guard let id = span.clipID, let clip = byID[id],
                      let source = try await sources.track(clip.url, .video) else { continue }
                let natural = try await source.track.load(.naturalSize)
                let preferred = try await source.track.load(.preferredTransform)
                let transform = fitTransform(natural: natural, preferred: preferred, render: renderSize,
                                             mode: project.video.fitMode)
                for segment in clip.segments() {
                    let segEnd = segment.timelineStart + segment.duration
                    let s0 = max(span.start, segment.timelineStart, window.lowerBound)
                    let s1 = min(span.end, segEnd, upper)
                    guard s1 - s0 > 0.001 else { continue }
                    let start = cm(s0)
                    if cursor == nil {
                        if s0 > 0 { track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: start)) }
                        cursor = start
                    } else if start > cursor! {
                        track.insertEmptyTimeRange(CMTimeRange(start: cursor!, duration: start - cursor!))
                        cursor = start
                    }
                    guard let at = cursor else { continue }
                    let srcStart = cm(segment.sourceStart + (s0 - segment.timelineStart))
                    var duration = cm(s1) - at
                    if srcStart + duration > source.range.end { duration = source.range.end - srcStart }
                    if duration.seconds <= 0.001 { continue }
                    try track.insertTimeRange(CMTimeRange(start: srcStart, duration: duration), of: source.track, at: at)
                    layer.setTransform(transform, at: at)
                    cursor = at + duration
                }
            }
            if cursor == nil {
                composition.removeTrack(track)
            } else {
                let vc = AVMutableVideoComposition()
                vc.renderSize = renderSize
                vc.frameDuration = CMTime(value: 1, timescale: 30)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.backgroundColor = cgColor(project.video.background)
                instruction.layerInstructions = [layer]
                vc.instructions = [instruction]
                videoComposition = vc
            }
        }

        var built = try await build(clips: project.clips, limit: limit, window: window, sources: sources, into: composition)
        if let vc = videoComposition, let instruction = vc.instructions.first as? AVMutableVideoCompositionInstruction {
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
            built.videoComposition = vc
        }
        return built
    }

    static func cgColor(_ c: RGBColor) -> CGColor {
        CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// Places a video track inside the output frame: upright (phone videos are often stored rotated),
    /// scaled to fit (with bars) or fill (cropped), and centred. The blurred style falls back to fit.
    static func fitTransform(natural: CGSize, preferred: CGAffineTransform, render: CGSize, mode: FitMode) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        let w = max(abs(oriented.width), 1), h = max(abs(oriented.height), 1)
        let scale = mode == .fill ? max(render.width / w, render.height / h) : min(render.width / w, render.height / h)
        return preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (render.width - w * scale) / 2, y: (render.height - h * scale) / 2))
    }
}

/// Small frames from each video file, for the timeline's filmstrips.
@MainActor
final class ThumbnailStore: ObservableObject {
    struct Thumb {
        let time: Double
        let image: NSImage
    }

    @Published private(set) var thumbnails: [URL: [Thumb]] = [:]
    private var loading: Set<URL> = []

    func request(_ url: URL) {
        guard thumbnails[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)
        Task.detached(priority: .utility) {
            let frames = await ThumbnailStore.compute(url)
            await MainActor.run {
                self.thumbnails[url] = frames.map { Thumb(time: $0.0, image: NSImage(cgImage: $0.1, size: .zero)) }
                self.loading.remove(url)
            }
        }
    }

    /// The thumbnail nearest to `time` seconds into the file.
    func thumbnail(for url: URL, at time: Double) -> NSImage? {
        guard let list = thumbnails[url], !list.isEmpty else { return nil }
        var best = list[0]
        for t in list where abs(t.time - time) < abs(best.time - time) { best = t }
        return best.image
    }

    nonisolated static func compute(_ url: URL) async -> [(Double, CGImage)] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 108)
        let tolerance = CMTime(seconds: min(1, duration / 20), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let count = min(48, max(6, Int(duration / 4)))
        var result: [(Double, CGImage)] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                result.append((t, image))
            }
        }
        return result
    }
}

/// Computes and caches a peak envelope per audio file for drawing waveforms.
@MainActor
final class WaveformStore: ObservableObject {
    nonisolated static let peaksPerSecond: Double = 50
    @Published private(set) var peaks: [URL: [Float]] = [:]
    private var loading: Set<URL> = []

    func request(_ url: URL) {
        guard peaks[url] == nil, !loading.contains(url) else { return }
        loading.insert(url)
        Task.detached(priority: .utility) {
            let result = (try? await WaveformStore.compute(url)) ?? []
            await MainActor.run {
                self.peaks[url] = result
                self.loading.remove(url)
            }
        }
    }

    nonisolated static func compute(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let sampleRate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let bucket = Int(sampleRate / peaksPerSecond)
        var peaks: [Float] = []
        var current: Int32 = 0
        var count = 0
        var samples = [Int16]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let n = length / 2
            if samples.count < n { samples = [Int16](repeating: 0, count: n) }
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 2, destination: raw.baseAddress!)
            }
            for i in 0..<n {
                let a = abs(Int32(samples[i]))
                if a > current { current = a }
                count += 1
                if count == bucket {
                    peaks.append(Float(current) / 32768)
                    current = 0
                    count = 0
                }
            }
        }
        if count > 0 { peaks.append(Float(current) / 32768) }
        // Normalise so quiet recordings are still visible.
        if let maxPeak = peaks.max(), maxPeak > 0.0001 {
            let scale = 1 / maxPeak
            peaks = peaks.map { min(1, $0 * scale) }
        }
        return peaks
    }
}
