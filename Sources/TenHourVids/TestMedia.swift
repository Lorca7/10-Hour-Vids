import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo

/// Generates sample video files for the self-test and the screenshots.
enum TestMedia {
    /// Writes an H.264 movie. `draw` paints frame `index` into a context of the given size.
    /// With `audio`, that file's sound is added for the movie's length.
    static func makeVideo(_ url: URL, width: Int, height: Int, fps: Int32, frames: Int, audio: URL? = nil,
                          draw: @escaping (Int, CGContext, CGSize) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        var steps: [(AVAssetWriterInput, () -> Bool)] = []
        let counter = Counter()
        steps.append((videoInput, {
            let i = counter.value
            guard i < frames, let buffer = TestMedia.makeFrame(i, width: width, height: height, draw: draw) else { return false }
            counter.value += 1
            return adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }))

        var reader: AVAssetReader?
        if let audio {
            let asset = AVURLAsset(url: audio)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw AppError("No audio in \(audio.lastPathComponent)") }
            let r = try AVAssetReader(asset: asset)
            r.timeRange = CMTimeRange(start: .zero, duration: CMTime(value: CMTimeValue(frames), timescale: fps))
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            r.add(output)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            audioInput.expectsMediaDataInRealTime = false
            writer.add(audioInput)
            reader = r
            steps.append((audioInput, {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                return audioInput.append(sample)
            }))
        }

        guard writer.startWriting() else { throw writer.error ?? AppError("Couldn’t write \(url.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)
        reader?.startReading()

        let group = DispatchGroup()
        for (n, step) in steps.enumerated() {
            let input = step.0
            let next = step.1
            let done = Counter()
            group.enter()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "TestMedia.\(n)")) {
                if done.value > 0 { return }
                while input.isReadyForMoreMediaData {
                    if !next() {
                        done.value = 1
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AppError("Couldn’t finish \(url.lastPathComponent)") }
    }

    private static func makeFrame(_ index: Int, width: Int, height: Int,
                                  draw: (Int, CGContext, CGSize) -> Void) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        draw(index, ctx, CGSize(width: width, height: height))
        return buffer
    }

    final class Counter: @unchecked Sendable {
        var value = 0
    }
}
