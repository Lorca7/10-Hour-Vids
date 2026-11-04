import Foundation
import AVFoundation

/// The timeline's audio clips assembled into one mixable composition.
struct BuiltAudio {
    let composition: AVMutableComposition
    let audioMix: AVMutableAudioMix
    /// Seconds of audio, already cut at the video's end.
    let duration: Double
}

enum CompositionBuilder {
    static let timescale: CMTimeScale = 48_000
    static func cm(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: timescale) }

    static func build(clips: [AudioClip], limit: Double) async throws -> BuiltAudio {
        let composition = AVMutableComposition()
        var params: [AVMutableAudioMixInputParameters] = []
        // Keep assets alive while the composition is built: a track only weakly references its asset.
        var sources: [URL: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)] = [:]
        var maxEnd = 0.0

        for clip in clips.sorted(by: { $0.start < $1.start }) {
            let clipEnd = min(clip.end, limit)
            guard clipEnd - clip.start > 0.01 else { continue }

            let source: (asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange)
            if let cached = sources[clip.url] {
                source = cached
            } else {
                let asset = AVURLAsset(url: clip.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                    throw AppError("“\(clip.name)” has no readable audio.")
                }
                let range = try await track.load(.timeRange)
                source = (asset, track, range)
                sources[clip.url] = source
            }

            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            var cursor = cm(clip.start)
            if clip.start > 0 {
                track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: cursor))
            }
            let endTime = cm(clipEnd)
            let sourceEnd = source.range.end
            for segment in clip.segments() {
                let remaining = endTime - cursor
                if remaining.seconds <= 0.001 { break }
                let srcStart = cm(segment.sourceStart)
                var duration = cm(segment.duration)
                if duration > remaining { duration = remaining }
                if srcStart + duration > sourceEnd { duration = sourceEnd - srcStart }
                if duration.seconds <= 0.001 { continue }
                try track.insertTimeRange(CMTimeRange(start: srcStart, duration: duration), of: source.track, at: cursor)
                cursor = cursor + duration
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
            maxEnd = max(maxEnd, cursor.seconds)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return BuiltAudio(composition: composition, audioMix: mix, duration: min(maxEnd, limit))
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
