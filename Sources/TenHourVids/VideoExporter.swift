import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox

/// Writes a YouTube-ready MP4 (H.264 video + AAC 48 kHz stereo audio).
///
/// Speed comes from never encoding the same pictures twice:
/// - The photo is encoded once as a 10-second run of frames, and that run is repeated wherever the
///   photo shows.
/// - A looped video clip is encoded once per loop and its compressed frames are repeated for every
///   further loop, so a 30-second clip looped for 10 hours costs about 30 seconds of encoding.
/// - Everything else goes through Apple's hardware video encoder (the media engine on Apple
///   silicon, Quick Sync on Intel Macs) when there is one, while the audio is encoded at the same
///   time on another core.
///
/// Every repeated run starts on a keyframe, so the result decodes like any ordinary video.
final class VideoExporter {
    private let token = CancelToken()
    private(set) var usedHardwareEncoder = false

    func cancel() { token.cancel() }

    func export(project: Project, settings: ExportSettings, to url: URL,
                progress: @escaping (Double, String) -> Void) async throws {
        let duration = min(max(project.video.duration, 1), Limits.maxDuration)
        var project = project
        project.video.duration = duration
        let fps = Int32(settings.fps)
        let width = settings.resolution.width, height = settings.resolution.height

        progress(0, "Rendering picture…")
        var image: CGImage?
        if let imageURL = project.imageURL {
            image = try ImageLoader.load(imageURL, maxPixel: max(width, height) * 2)
        }
        let photoFrame = try FrameRenderer.makePixelBuffer(image: image, width: width, height: height,
                                                           mode: project.video.fitMode,
                                                           background: project.video.background)

        let gopFrames = Int(fps) * ExportSettings.keyframeInterval
        let encoder = try FrameEncoder(width: width, height: height, fps: fps,
                                       bitrate: settings.resolution.bitrate, keyframeInterval: gopFrames)
        usedHardwareEncoder = encoder.usesHardware

        progress(0, "Encoding picture…")
        for i in 0..<gopFrames { try encoder.encode(photoFrame, keyframe: i == 0) }
        let gop = try encoder.finish()
        guard gop.count == gopFrames, let format = gop.first.flatMap(CMSampleBufferGetFormatDescription) else {
            throw AppError("The video encoder produced no frames.")
        }
        if token.isCancelled { throw CancellationError() }

        let plan = VideoPlan(project: project, fps: fps, bitrate: settings.resolution.bitrate)

        var audio: BuiltAudio?
        if !project.clips.isEmpty {
            progress(0, "Preparing audio…")
            let built = try await CompositionBuilder.build(clips: project.clips, limit: duration)
            if built.duration > 0.05 { audio = built }
        }
        if token.isCancelled { throw CancellationError() }

        let context = ClipRenderContext(size: CGSize(width: width, height: height), fps: fps,
                                        mode: project.video.fitMode, background: project.video.background)
        try? FileManager.default.removeItem(at: url)
        try await writeMovie(plan: plan, gop: gop, format: format, encoder: encoder, context: context,
                             audio: audio, duration: duration, audioBitrate: settings.audioBitrate,
                             to: url, progress: progress)
    }

    // MARK: - Movie writing

    private func writeMovie(plan: VideoPlan, gop: [CMSampleBuffer], format: CMFormatDescription,
                            encoder: FrameEncoder, context: ClipRenderContext,
                            audio: BuiltAudio?, duration: Double, audioBitrate: Int,
                            to url: URL, progress: @escaping (Double, String) -> Void) async throws {
        let fps = context.fps
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
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
        let audioGroup = DispatchGroup()

        // Audio is decoded, mixed and encoded on its own queue while the video is produced below.
        if let audioInput, let audioOutput, let reader {
            audioGroup.enter()
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "TenHourVids.audio")) {
                if state.audioDone { return }
                while audioInput.isReadyForMoreMediaData {
                    if token.isCancelled || state.hasError {
                        state.audioDone = true
                        audioInput.markAsFinished()
                        audioGroup.leave()
                        return
                    }
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        if !audioInput.append(sample) {
                            state.fail(writer.error ?? AppError("Writing the audio failed."))
                            state.audioDone = true
                            audioInput.markAsFinished()
                            audioGroup.leave()
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
                        audioGroup.leave()
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
                progress(min(max(p, 0), 0.999), state.phase)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { reporter.cancel() }

        let totalFrames = Int64(plan.totalFrames)
        var outIndex: Int64 = 0

        func emit(_ sample: CMSampleBuffer) async throws {
            while !videoInput.isReadyForMoreMediaData {
                if token.isCancelled { throw CancellationError() }
                if let error = state.error { throw error }
                if writer.status == .failed { throw writer.error ?? AppError("Writing the video failed.") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let copy = try Self.retimed(sample, index: outIndex, fps: fps)
            guard videoInput.append(copy) else { throw writer.error ?? AppError("Writing the video failed.") }
            outIndex += 1
            if outIndex % 128 == 0 { state.videoProgress = Double(outIndex) / Double(max(totalFrames, 1)) }
        }

        do {
            var cache: [SourceKey: [CMSampleBuffer]] = [:]
            for run in plan.runs {
                if token.isCancelled { throw CancellationError() }
                switch run.source {
                case .photo:
                    state.phase = "Writing video…"
                    for k in 0..<run.frames { try await emit(gop[k % gop.count]) }
                case .clip(let key):
                    if let needed = plan.cachedFrames[key] {
                        if cache[key] == nil {
                            state.phase = "Encoding video loop…"
                            var collected: [CMSampleBuffer] = []
                            try await encodeClip(key, frames: needed, encoder: encoder, context: context) { batch in
                                collected.append(contentsOf: batch)
                            }
                            cache[key] = collected
                        }
                        state.phase = "Writing video…"
                        let samples = cache[key]!
                        for k in 0..<min(run.frames, samples.count) { try await emit(samples[k]) }
                    } else {
                        state.phase = "Encoding video…"
                        try await encodeClip(key, frames: run.frames, encoder: encoder, context: context) { batch in
                            for sample in batch { try await emit(sample) }
                        }
                    }
                }
            }
            state.videoProgress = 1
            videoInput.markAsFinished()
        } catch {
            reader?.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioGroup.notify(queue: .global()) { continuation.resume() }
        }

        if token.isCancelled || state.error != nil {
            reader?.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            if let error = state.error { throw error }
            throw CancellationError()
        }

        progress(1, "Finishing file…")
        writer.endSession(atSourceTime: CMTime(value: outIndex, timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? AppError("The video file couldn’t be finished.")
        }
    }

    // MARK: - Video clips

    /// Decodes `frames` frames of a video file starting at `key.start`, scaled into the output frame
    /// (hardware decoding and GPU scaling via AVFoundation), and encodes them, first frame as a keyframe.
    /// Compressed frames are handed to `sink` as soon as the encoder produces them.
    private func encodeClip(_ key: SourceKey, frames: Int, encoder: FrameEncoder, context: ClipRenderContext,
                            sink: ([CMSampleBuffer]) async throws -> Void) async throws {
        let rate = Double(context.fps)
        let asset = AVURLAsset(url: key.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppError("“\(key.url.lastPathComponent)” has no readable video.")
        }
        let range = try await track.load(.timeRange)
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)

        let sourceEnd = range.end.seconds
        let start = min(max(key.start, range.start.seconds), max(range.start.seconds, sourceEnd - 1 / rate))
        let length = max(1 / rate, min(Double(frames) / rate, sourceEnd - start))

        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AppError("Couldn’t prepare “\(key.url.lastPathComponent)”.")
        }
        try compTrack.insertTimeRange(CMTimeRange(start: CompositionBuilder.cm(start), duration: CompositionBuilder.cm(length)),
                                      of: track, at: .zero)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = context.size
        videoComposition.frameDuration = CMTime(value: 1, timescale: context.fps)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.backgroundColor = CompositionBuilder.cgColor(context.background)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
        layer.setTransform(CompositionBuilder.fitTransform(natural: natural, preferred: preferred,
                                                           render: context.size, mode: context.mode), at: .zero)
        instruction.layerInstructions = [layer]
        videoComposition.instructions = [instruction]

        let reader = try AVAssetReader(asset: composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [compTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AppError("Couldn’t read “\(key.url.lastPathComponent)”.") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? AppError("Couldn’t read “\(key.url.lastPathComponent)”.")
        }
        defer { reader.cancelReading() }

        let submittedBefore = encoder.submitted
        var last: CVPixelBuffer?
        for i in 0..<frames {
            if token.isCancelled { throw CancellationError() }
            var buffer: CVPixelBuffer?
            if let sample = output.copyNextSampleBuffer() {
                buffer = CMSampleBufferGetImageBuffer(sample)
            } else if reader.status == .failed {
                throw reader.error ?? AppError("Couldn’t read “\(key.url.lastPathComponent)”.")
            }
            // At the very end of a file there can be a frame or two fewer than needed: hold the last one.
            guard let frame = buffer ?? last else {
                throw AppError("“\(key.url.lastPathComponent)” has no frames at \(Timecode.format(start)).")
            }
            last = frame
            try encoder.encode(frame, keyframe: i == 0)
            let ready = try encoder.takeReady()
            if !ready.isEmpty { try await sink(ready) }
        }
        let rest = try encoder.finish()
        if !rest.isEmpty { try await sink(rest) }
        guard encoder.submitted - submittedBefore == frames else { throw AppError("The video encoder lost frames.") }
    }

    static func retimed(_ sample: CMSampleBuffer, index: Int64, fps: Int32) throws -> CMSampleBuffer {
        let pts = CMTime(value: index, timescale: fps)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps), presentationTimeStamp: pts, decodeTimeStamp: pts)
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                           sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw AppError("Couldn’t place a video frame.") }
        return copy
    }
}

struct ClipRenderContext {
    let size: CGSize
    let fps: Int32
    let mode: FitMode
    let background: RGBColor
}

// MARK: - Plan

/// A point in a video file: frames encoded from here can be reused wherever the same point is needed.
struct SourceKey: Hashable {
    let url: URL
    let millis: Int64
    init(url: URL, start: Double) {
        self.url = url
        millis = Int64((start * 1000).rounded())
    }
    var start: Double { Double(millis) / 1000 }
}

struct VideoRun: Equatable {
    enum Source: Equatable {
        case photo
        case clip(SourceKey)
    }
    let source: Source
    let frames: Int
}

/// The finished video as an ordered list of runs of frames, each from the photo or from a point in a
/// video file. Starts that occur more than once (every pass of a loop) are encoded once and reused.
struct VideoPlan {
    let runs: [VideoRun]
    let totalFrames: Int
    /// Starts to encode once and reuse, with the most frames any run needs from them.
    let cachedFrames: [SourceKey: Int]

    /// Upper limit on memory for one reusable encoded loop.
    static let maxCachedBytes = 1_000_000_000.0

    init(project: Project, fps: Int32, bitrate: Int) {
        let rate = Double(fps)
        func frame(_ t: Double) -> Int { Int((t * rate - 1e-6).rounded(.up)) }
        let byID = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.id, $0) })

        var runs: [VideoRun] = []
        for span in project.videoSpans() {
            guard let id = span.clipID, let clip = byID[id] else {
                let n = frame(span.end) - frame(span.start)
                if n > 0 { runs.append(VideoRun(source: .photo, frames: n)) }
                continue
            }
            for segment in clip.segments() {
                let s0 = max(span.start, segment.timelineStart)
                let s1 = min(span.end, segment.timelineStart + segment.duration)
                guard s1 > s0 else { continue }
                let n = frame(s1) - frame(s0)
                guard n > 0 else { continue }
                let key = SourceKey(url: clip.url, start: segment.sourceStart + (s0 - segment.timelineStart))
                runs.append(VideoRun(source: .clip(key), frames: n))
            }
        }

        var uses: [SourceKey: (count: Int, frames: Int)] = [:]
        for run in runs {
            if case .clip(let key) = run.source {
                let u = uses[key] ?? (0, 0)
                uses[key] = (u.count + 1, max(u.frames, run.frames))
            }
        }
        var cached: [SourceKey: Int] = [:]
        for (key, u) in uses where u.count >= 2 && Double(u.frames) / rate * Double(bitrate) / 8 <= Self.maxCachedBytes {
            cached[key] = u.frames
        }

        self.runs = runs
        self.cachedFrames = cached
        self.totalFrames = runs.reduce(0) { $0 + $1.frames }
    }

    /// Frames that have to go through the encoder (the rest are copies).
    var encodedFrames: Int {
        var seen: Set<SourceKey> = []
        var total = 0
        for run in runs {
            guard case .clip(let key) = run.source else { continue }
            if let n = cachedFrames[key] {
                if seen.insert(key).inserted { total += n }
            } else {
                total += run.frames
            }
        }
        return total
    }
}

// MARK: - Encoder

/// One H.264 encoder (VideoToolbox) shared by the whole export, so every frame in the file has the
/// same stream settings. Prefers the hardware encoder and falls back to software.
final class FrameEncoder {
    private let session: VTCompressionSession
    let fps: Int32
    let usesHardware: Bool
    private var nextPTS: Int64 = 0
    private(set) var submitted = 0
    private let lock = NSLock()
    private var ready: [CMSampleBuffer] = []
    private var received = 0
    private var failure: OSStatus = noErr

    init(width: Int, height: Int, fps: Int32, bitrate: Int, keyframeInterval: Int) throws {
        let session = try Self.makeSession(width: width, height: height)
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: keyframeInterval))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: Double(keyframeInterval) / Double(fps)))
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
        self.fps = fps
        self.usesHardware = Self.isHardware(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    private static func makeSession(width: Int, height: Int) throws -> VTCompressionSession {
        let spec: [String: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw AppError("The H.264 video encoder couldn’t start (error \(status)).")
        }
        return session
    }

    private static func isHardware(_ session: VTCompressionSession) -> Bool {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  allocator: kCFAllocatorDefault, valueOut: $0)
        }
        return status == noErr && (value as? Bool) == true
    }

    /// Whether this Mac encodes H.264 at this size in hardware.
    static func hardwareAvailable(width: Int, height: Int) -> Bool {
        guard let session = try? makeSession(width: width, height: height) else { return false }
        defer { VTCompressionSessionInvalidate(session) }
        return isHardware(session)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, keyframe: Bool) throws {
        let pts = CMTime(value: nextPTS, timescale: fps)
        nextPTS += 1
        let properties: CFDictionary? = keyframe
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary) : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                                     duration: CMTime(value: 1, timescale: fps),
                                                     frameProperties: properties, infoFlagsOut: nil) { [weak self] status, flags, sample in
            guard let self else { return }
            self.lock.lock()
            self.received += 1
            if status != noErr {
                self.failure = status
            } else if flags.contains(.frameDropped) {
                self.failure = -1
            } else if let sample {
                self.ready.append(sample)
            }
            self.lock.unlock()
        }
        guard status == noErr else { throw AppError("The video encoder stopped (error \(status)).") }
        submitted += 1
    }

    /// Compressed frames finished so far, in order.
    func takeReady() throws -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        if failure != noErr { throw AppError("The video encoder failed (error \(failure)).") }
        let out = ready
        ready.removeAll(keepingCapacity: true)
        return out.sorted { CMSampleBufferGetPresentationTimeStamp($0) < CMSampleBufferGetPresentationTimeStamp($1) }
    }

    /// Waits for every submitted frame and returns the remaining compressed frames.
    func finish() throws -> [CMSampleBuffer] {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let out = try takeReady()
        lock.lock()
        let complete = received == submitted
        lock.unlock()
        guard complete else { throw AppError("The video encoder didn’t finish every frame.") }
        return out
    }
}

// MARK: - Shared state

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// State shared between the video writer, the audio queue and the progress reporter.
final class PumpState: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    private var _videoProgress = 0.0
    private var _audioProgress = 0.0
    private var _phase = "Writing video…"
    var audioDone = false  // only touched on the audio queue

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
    var phase: String {
        get { lock.lock(); defer { lock.unlock() }; return _phase }
        set { lock.lock(); _phase = newValue; lock.unlock() }
    }
}

// MARK: - This Mac

enum HardwareInfo {
    static var cpuName: String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "This Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "This Mac" }
        return String(cString: buffer)
    }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// e.g. "Apple M2 · hardware H.264 encoder (media engine) · 8 cores"
    static func summary(width: Int = 1920, height: Int = 1080) -> String {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let encoder: String
        if FrameEncoder.hardwareAvailable(width: width, height: height) {
            encoder = isAppleSilicon ? "hardware H.264 encoder (media engine)" : "hardware H.264 encoder (Quick Sync)"
        } else {
            encoder = "software H.264 encoder"
        }
        return "\(cpuName) · \(encoder) · \(cores) cores"
    }
}
