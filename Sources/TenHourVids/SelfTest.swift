import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Headless checks of the editing logic and the full export pipeline.
enum SelfTest {
    private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("  ok   \(message)")
        } else {
            print("  FAIL \(message)")
            failures += 1
        }
    }

    static func run(long: Bool) async -> Bool {
        print("10 Hour Vids self-test")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thv-selftest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            print("Editing logic")
            testClipMath()
            await testEditorModel()

            let imageURL = dir.appendingPathComponent("photo.png")
            let toneURL = dir.appendingPathComponent("tone.wav")
            try makeTestImage(imageURL)
            try makeTone(toneURL, seconds: 20)

            print("Waveform")
            let peaks = try await WaveformStore.compute(toneURL)
            check(abs(Double(peaks.count) - 20 * WaveformStore.peaksPerSecond) <= 2, "waveform has \(peaks.count) peaks for 20 s")
            check((peaks.max() ?? 0) > 0.9, "waveform is normalised")

            let tone = AudioClip(url: toneURL, name: "tone", sourceDuration: 20, inPoint: 0, outPoint: 20,
                                 start: 0, length: 20, lane: 0)

            print("Export 1: 75 s, 1080p30, fit, looped audio with fades + a second overlapping clip")
            var project = Project()
            project.imageURL = imageURL
            project.video.duration = 75
            var looped = tone
            looped.loop = true
            looped.length = 75
            looped.fadeIn = 2
            looped.fadeOut = 3
            var second = tone
            second.id = UUID()
            second.start = 10
            second.lane = 1
            second.volume = 0.5
            project.clips = [looped, second]
            try await exportAndVerify(project, ExportSettings(), to: dir.appendingPathComponent("a.mp4"),
                                      expectPillarbox: true)

            print("Export 2: 60 s, 720p25, blurred background, no audio")
            project = Project()
            project.imageURL = imageURL
            project.video.duration = 60
            project.video.fitMode = .blur
            var settings = ExportSettings()
            settings.resolution = .hd720
            settings.fps = 25
            try await exportAndVerify(project, settings, to: dir.appendingPathComponent("b.mp4"), expectPillarbox: false)

            print("Export 3: 2 min, 4K24, fill, audio shorter than video, starting at 0:30")
            project = Project()
            project.imageURL = imageURL
            project.video.duration = 120
            project.video.fitMode = .fill
            var late = tone
            late.start = 30
            project.clips = [late]
            settings = ExportSettings()
            settings.resolution = .uhd2160
            settings.fps = 24
            settings.audioBitrate = 320_000
            try await exportAndVerify(project, settings, to: dir.appendingPathComponent("c.mp4"), expectPillarbox: false,
                                      loudAt: 40, quietAt: 10)

            if long {
                print("Export 4: 10 hours, 1080p30, looped audio (speed test)")
                project = Project()
                project.imageURL = imageURL
                project.video.duration = Limits.maxDuration
                var all = tone
                all.loop = true
                all.length = Limits.maxDuration
                all.fadeOut = 10
                project.clips = [all]
                try await exportAndVerify(project, ExportSettings(), to: dir.appendingPathComponent("d.mp4"),
                                          expectPillarbox: true, loudAt: 30_000)
            }
        } catch {
            print("  FAIL unexpected error: \(error.localizedDescription)")
            failures += 1
        }
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        return failures == 0
    }

    // MARK: - Logic

    private static func testClipMath() {
        check(Timecode.parse("1:02:03.5") == 3723.5, "parse H:MM:SS.s")
        check(Timecode.parse("10:00") == 600, "parse MM:SS")
        check(Timecode.parse("90") == 90, "parse seconds")
        check(Timecode.parse("abc") == nil, "reject bad text")
        check(Timecode.format(36000) == "10:00:00", "format 10 hours")
        check(Timecode.format(3723.46, tenths: true) == "1:02:03.5", "format tenths")

        let url = URL(fileURLWithPath: "/tmp/x.wav")
        var c = AudioClip(url: url, name: "x", sourceDuration: 100, inPoint: 10, outPoint: 40,
                          start: 5, length: 70, lane: 0)
        c.loop = true
        c.normalize()
        let segs = c.segments()
        check(segs.count == 3, "70 s loop of a 30 s region has 3 segments")
        check(abs(segs.map(\.duration).reduce(0, +) - 70) < 1e-6, "segments add up to clip length")
        check(abs(c.sourceTime(at: 5 + 31) - 11) < 1e-6, "looped source time wraps")

        if let halves = c.split(at: 50) {
            let (a, b) = halves
            check(abs(a.length - 45) < 1e-6 && abs(b.start - 50) < 1e-6 && abs(b.length - 25) < 1e-6, "split lengths")
            check(abs(b.sourceTime(at: 50) - c.sourceTime(at: 50)) < 1e-6, "split keeps looped audio continuous")
        } else {
            check(false, "split succeeded")
        }

        var plain = AudioClip(url: url, name: "p", sourceDuration: 60, inPoint: 0, outPoint: 60,
                              start: 0, length: 60, lane: 0)
        if let halves = plain.split(at: 20) {
            check(abs(halves.0.outPoint - 20) < 1e-6 && abs(halves.1.inPoint - 20) < 1e-6, "split plain clip source points")
        } else {
            check(false, "split plain clip")
        }
        plain.length = 500
        plain.normalize()
        check(abs(plain.length - 60) < 1e-6, "plain clip can’t be longer than its file")
        plain.fadeIn = 50
        plain.fadeOut = 50
        plain.normalize()
        check(plain.fadeIn + plain.fadeOut <= plain.length + 1e-6, "fades fit inside the clip")
    }

    private static func testEditorModel() async {
        await MainActor.run {
            let model = EditorModel()
            let url = URL(fileURLWithPath: "/tmp/x.wav")
            var c = AudioClip(url: url, name: "x", sourceDuration: 120, inPoint: 0, outPoint: 120,
                              start: 0, length: 120, lane: 0)
            c.normalize()
            model.checkpoint()
            model.project.clips = [c]
            model.pixelsPerSecond = 10
            model.setDuration(30)
            check(model.project.video.duration == 60, "video length is at least 1 minute")
            model.setDuration(50_000)
            check(model.project.video.duration == 36_000, "video length is at most 10 hours")

            model.trimClip(c.id, edge: .left, origin: c, delta: 10)
            let trimmed = model.clip(c.id)!
            check(abs(trimmed.start - 10) < 1e-6 && abs(trimmed.inPoint - 10) < 1e-6 && abs(trimmed.length - 110) < 1e-6,
                  "trim start")
            model.trimClip(c.id, edge: .right, origin: trimmed, delta: 500)
            check(abs(model.clip(c.id)!.end - 120) < 1e-6, "trim end stops at the end of the file")

            model.playhead = 60
            model.selection = .clip(c.id)
            model.splitAtPlayhead()
            check(model.project.clips.count == 2, "split at playhead")
            model.undo()
            check(model.project.clips.count == 1, "undo split")
            model.redo()
            check(model.project.clips.count == 2, "redo split")

            model.setDuration(3600)
            model.fillToEnd(model.project.clips[1].id)
            check(abs(model.project.clips[1].end - 3600) < 1e-6 && model.project.clips[1].loop, "loop to end of video")
            model.matchAudioLength()
            check(model.project.video.duration == 3600, "match video length to audio")
        }
    }

    // MARK: - Export checks

    private static func exportAndVerify(_ project: Project, _ settings: ExportSettings, to url: URL,
                                        expectPillarbox: Bool, loudAt: Double? = nil, quietAt: Double? = nil) async throws {
        let start = Date()
        try await VideoExporter().export(project: project, settings: settings, to: url) { _, _ in }
        let seconds = Date().timeIntervalSince(start)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print("  ..   exported in \(String(format: "%.1f", seconds)) s, \(Timecode.byteCount(Double(size)))")

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        check(abs(duration - project.video.duration) < 0.5,
              "duration \(String(format: "%.2f", duration)) s ≈ \(project.video.duration) s")

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        check(videoTracks.count == 1, "one video track")
        if let v = videoTracks.first {
            let natural = try await v.load(.naturalSize)
            check(Int(natural.width) == settings.resolution.width && Int(natural.height) == settings.resolution.height,
                  "video is \(Int(natural.width))×\(Int(natural.height))")
            let fps = try await v.load(.nominalFrameRate)
            check(abs(Double(fps) - Double(settings.fps)) < 0.5, "frame rate \(fps)")
            let formats = try await v.load(.formatDescriptions)
            check(formats.first.map { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 } ?? false, "H.264 video")
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        check(audioTracks.count == (project.clips.isEmpty ? 0 : 1), "\(audioTracks.count) audio track(s)")
        if let a = audioTracks.first {
            let formats = try await a.load(.formatDescriptions)
            if let f = formats.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee {
                check(asbd.mFormatID == kAudioFormatMPEG4AAC && asbd.mSampleRate == 48_000 && asbd.mChannelsPerFrame == 2,
                      "AAC 48 kHz stereo audio")
            } else {
                check(false, "audio format readable")
            }
            if let loudAt {
                let rms = try await audioRMS(asset, track: a, at: loudAt)
                check(rms > 0.05, "audio audible at \(Timecode.format(loudAt)) (rms \(String(format: "%.3f", rms)))")
            }
            if let quietAt {
                let rms = try await audioRMS(asset, track: a, at: quietAt)
                check(rms < 0.01, "silence at \(Timecode.format(quietAt)) (rms \(String(format: "%.3f", rms)))")
            }
        }

        // Decode frames at the start, middle and end.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for t in [0.2, project.video.duration / 2, project.video.duration - 0.5] {
            let image = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            let center = pixel(image, x: 0.5, y: 0.5)
            check(center.r > 0.75 && center.g > 0.3 && center.g < 0.7 && center.b < 0.3,
                  "frame at \(Timecode.format(t)) shows the photo (centre \(fmt(center)))")
            if expectPillarbox {
                let edge = pixel(image, x: 0.03, y: 0.5)
                check(edge.r < 0.08 && edge.g < 0.08 && edge.b < 0.08, "black bars beside the photo (\(fmt(edge)))")
            }
        }
    }

    private static func fmt(_ c: (r: Double, g: Double, b: Double)) -> String {
        String(format: "%.2f,%.2f,%.2f", c.r, c.g, c.b)
    }

    private static func audioRMS(_ asset: AVAsset, track: AVAssetTrack, at t: Double) async throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 48_000),
                                       duration: CMTime(seconds: 1, preferredTimescale: 48_000))
        guard reader.startReading() else { throw reader.error ?? AppError("read failed") }
        var sum = 0.0
        var n = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Int16](repeating: 0, count: length / 2)
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length / 2 * 2, destination: raw.baseAddress!)
            }
            for s in samples {
                let v = Double(s) / 32768
                sum += v * v
            }
            n += samples.count
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }

    private static func pixel(_ image: CGImage, x: Double, y: Double) -> (r: Double, g: Double, b: Double) {
        let w = 160, h = 90
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = min(w - 1, Int(Double(w) * x))
        let py = min(h - 1, Int(Double(h) * y))
        let i = (py * w + px) * 4
        return (Double(data[i]) / 255, Double(data[i + 1]) / 255, Double(data[i + 2]) / 255)
    }

    // MARK: - Test media

    /// A 3:2 orange photo with a white circle off to one side.
    private static func makeTestImage(_ url: URL) throws {
        let w = 3000, h = 2000
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppError("ctx") }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 200, y: 200, width: 600, height: 600))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw AppError("image") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw AppError("png") }
    }

    private static func makeTone(_ url: URL, seconds: Double) throws {
        let rate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(rate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              let channels = buffer.floatChannelData else { throw AppError("buffer") }
        buffer.frameLength = frames
        for ch in 0..<Int(file.processingFormat.channelCount) {
            for i in 0..<Int(frames) {
                channels[ch][i] = Float(0.4 * sin(2 * Double.pi * 440 * Double(i) / rate))
            }
        }
        try file.write(from: buffer)
    }
}
