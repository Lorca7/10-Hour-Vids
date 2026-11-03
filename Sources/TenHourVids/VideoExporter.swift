import Foundation
import AVFoundation
import CoreVideo

/// Writes a YouTube-ready MP4 (H.264 video + AAC 48 kHz stereo audio).
///
/// Encoding hours of an unchanging picture frame by frame would be very slow, so the exporter
/// encodes one keyframe interval (10 seconds) of the still picture once, then writes those
/// already-compressed frames over and over with new timestamps. Every repeat starts on a
/// keyframe, so the stream decodes correctly everywhere. Only the audio is encoded for its
/// full length, which is quick. A 10-hour video takes minutes rather than hours.
final class VideoExporter {
    private let token = CancelToken()

    func cancel() { token.cancel() }

    struct EncodedGOP {
        let samples: [CMSampleBuffer]
        let format: CMFormatDescription
        let bytes: Int
    }

    func export(project: Project, settings: ExportSettings, to url: URL,
                progress: @escaping (Double, String) -> Void) async throws {
        let duration = min(max(project.video.duration, 1), Limits.maxDuration)
        let fps = Int32(settings.fps)
        let width = settings.resolution.width, height = settings.resolution.height

        progress(0, "Rendering picture…")
        var image: CGImage?
        if let imageURL = project.imageURL {
            image = try ImageLoader.load(imageURL, maxPixel: max(width, height) * 2)
        }
        let pixelBuffer = try FrameRenderer.makePixelBuffer(image: image, width: width, height: height,
                                                            mode: project.video.fitMode,
                                                            background: project.video.background)

        progress(0, "Encoding picture…")
        let gopFrames = Int(fps) * ExportSettings.keyframeInterval
        let gop = try await encodeGOP(pixelBuffer: pixelBuffer, width: width, height: height, fps: fps,
                                      frames: gopFrames, bitrate: settings.resolution.bitrate)
        if token.isCancelled { throw CancellationError() }

        var audio: BuiltAudio?
        if !project.clips.isEmpty {
            progress(0, "Preparing audio…")
            let built = try await CompositionBuilder.build(clips: project.clips, limit: duration)
            if built.duration > 0.05 { audio = built }
        }
        if token.isCancelled { throw CancellationError() }

        try? FileManager.default.removeItem(at: url)
        try await writeMovie(gop: gop, audio: audio, duration: duration, fps: fps,
                             audioBitrate: settings.audioBitrate, to: url, progress: progress)
    }

    // MARK: - Still picture

    private func encodeGOP(pixelBuffer: CVPixelBuffer, width: Int, height: Int, fps: Int32,
                           frames: Int, bitrate: Int) async throws -> EncodedGOP {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("thv-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: frames,
            AVVideoMaxKeyFrameIntervalDurationKey: Double(frames) / Double(fps),
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
            AVVideoExpectedSourceFrameRateKey: Int(fps),
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw AppError("The H.264 video encoder isn’t available.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppError("Couldn’t start the video encoder.") }
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? AppError("Video encoding failed.") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            if !adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)) {
                throw writer.error ?? AppError("Video encoding failed.")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AppError("Video encoding failed.") }

        // Read the compressed frames back so they can be repeated without re-encoding.
        let asset = AVURLAsset(url: tmp)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("The encoded picture couldn’t be read back.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = true
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AppError("The encoded picture couldn’t be read back.") }
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 1 { samples.append(sample) }
        }
        if reader.status == .failed { throw reader.error ?? AppError("The encoded picture couldn’t be read back.") }
        samples.sort { CMSampleBufferGetPresentationTimeStamp($0) < CMSampleBufferGetPresentationTimeStamp($1) }
        guard let first = samples.first, let format = CMSampleBufferGetFormatDescription(first) else {
            throw AppError("The video encoder produced no frames.")
        }
        let bytes = samples.reduce(0) { $0 + CMSampleBufferGetTotalSampleSize($1) }
        return EncodedGOP(samples: samples, format: format, bytes: bytes)
    }

    // MARK: - Final movie

    private func writeMovie(gop: EncodedGOP, audio: BuiltAudio?, duration: Double, fps: Int32, audioBitrate: Int,
                            to url: URL, progress: @escaping (Double, String) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: gop.format)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw AppError("Couldn’t add the video track.") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var reader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        let audioEnd = audio.map { min($0.duration, duration) } ?? 0

        if let audio {
            let r = try AVAssetReader(asset: audio.composition)
            let tracks = audio.composition.tracks(withMediaType: .audio)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = audio.audioMix
            output.alwaysCopiesSampleData = false
            guard r.canAdd(output) else { throw AppError("Couldn’t read the audio mix.") }
            r.add(output)
            r.timeRange = CMTimeRange(start: .zero, duration: CompositionBuilder.cm(audioEnd))

            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitrate,
                AVChannelLayoutKey: layoutData,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw AppError("These AAC audio settings aren’t supported.") }
            writer.add(input)
            audioInput = input
            reader = r
            audioOutput = output
        }

        guard writer.startWriting() else { throw writer.error ?? AppError("Couldn’t create “\(url.lastPathComponent)”.") }
        writer.startSession(atSourceTime: .zero)
        if let reader, !reader.startReading() {
            writer.cancelWriting()
            throw reader.error ?? AppError("Couldn’t start reading the audio.")
        }

        let state = PumpState()
        let token = self.token
        let group = DispatchGroup()
        let totalFrames = max(1, Int64((duration * Double(fps)).rounded()))
        let frameDuration = CMTime(value: 1, timescale: fps)
        let gopCount = Int64(gop.samples.count)

        group.enter()
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "TenHourVids.video")) {
            if state.videoDone { return }
            while videoInput.isReadyForMoreMediaData {
                let index = state.frameIndex
                if token.isCancelled || state.hasError || index >= totalFrames {
                    state.videoProgress = 1
                    state.videoDone = true
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                let source = gop.samples[Int(index % gopCount)]
                let pts = CMTime(value: index, timescale: fps)
                var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: pts, decodeTimeStamp: pts)
                var copy: CMSampleBuffer?
                let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: source,
                                                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                                   sampleBufferOut: &copy)
                guard status == noErr, let copy, videoInput.append(copy) else {
                    state.fail(writer.error ?? AppError("Writing the video failed."))
                    state.videoDone = true
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                state.frameIndex = index + 1
                if index % 256 == 0 { state.videoProgress = Double(index) / Double(totalFrames) }
            }
        }

        if let audioInput, let audioOutput, let reader {
            group.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "TenHourVids.audio")) {
                if state.audioDone { return }
                while audioInput.isReadyForMoreMediaData {
                    if token.isCancelled || state.hasError {
                        state.audioDone = true
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        if !audioInput.append(sample) {
                            state.fail(writer.error ?? AppError("Writing the audio failed."))
                            state.audioDone = true
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        if audioEnd > 0 { state.audioProgress = t / audioEnd }
                    } else {
                        if reader.status == .failed {
                            state.fail(reader.error ?? AppError("Reading the audio failed."))
                        }
                        state.audioProgress = 1
                        state.audioDone = true
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        } else {
            state.audioProgress = 1
        }

        let reporter = Task {
            while !Task.isCancelled {
                let p = min(state.videoProgress, state.audioProgress)
                progress(min(max(p, 0), 0.999), "Writing video…")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        reporter.cancel()

        if token.isCancelled || state.error != nil {
            reader?.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            if let error = state.error { throw error }
            throw CancellationError()
        }

        progress(1, "Finishing file…")
        writer.endSession(atSourceTime: CMTime(value: totalFrames, timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? AppError("The video file couldn’t be finished.")
        }
    }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Shared state between the video and audio writer queues and the progress reporter.
final class PumpState: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    private var _videoProgress = 0.0
    private var _audioProgress = 0.0
    // Only touched from the video queue / audio queue respectively.
    var frameIndex: Int64 = 0
    var videoDone = false
    var audioDone = false

    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
    var hasError: Bool { error != nil }
    func fail(_ e: Error) { lock.lock(); if _error == nil { _error = e }; lock.unlock() }

    var videoProgress: Double {
        get { lock.lock(); defer { lock.unlock() }; return _videoProgress }
        set { lock.lock(); _videoProgress = newValue; lock.unlock() }
    }
    var audioProgress: Double {
        get { lock.lock(); defer { lock.unlock() }; return _audioProgress }
        set { lock.lock(); _audioProgress = newValue; lock.unlock() }
    }
}
