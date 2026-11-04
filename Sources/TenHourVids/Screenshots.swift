import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `--screenshots <dir>` opens the real interface with a sample project and saves PNGs of it.
@MainActor
enum Screenshots {
    static func run(into outDir: URL) async -> Bool {
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("thv-shots-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            let photo = work.appendingPathComponent("Mountain Lake.png")
            let rain = work.appendingPathComponent("Rain on Window.wav")
            let piano = work.appendingPathComponent("Soft Piano.wav")
            try makePhoto(photo)
            try makeAudio(rain, seconds: 60, kind: .rain)
            try makeAudio(piano, seconds: 45, kind: .piano)

            let size = CGSize(width: 1320, height: 860)

            // 1. First launch
            let empty = EditorModel()
            try await capture(ContentView(model: empty), size: size, dark: false, to: outDir.appendingPathComponent("01-empty.png"))

            // 2. Photo and audio loaded, video selected
            let model = makeModel(photo: photo, rain: rain, piano: piano)
            model.selection = .video
            try await capture(ContentView(model: model), size: size, dark: false, to: outDir.appendingPathComponent("02-video-settings.png"))

            // 3. An audio clip selected
            if let clip = model.project.clips.first { model.selection = .clip(clip.id) }
            try await capture(ContentView(model: model), size: size, dark: false, to: outDir.appendingPathComponent("03-audio-clip.png"))

            // 4. Dark mode
            try await capture(ContentView(model: model), size: size, dark: true, to: outDir.appendingPathComponent("04-dark-mode.png"))

            // 5. Export dialog
            try await capture(ExportSheet(model: model), size: CGSize(width: 500, height: 470), dark: false,
                              to: outDir.appendingPathComponent("05-export.png"))
            print("Saved screenshots to \(outDir.path)")
            return true
        } catch {
            print("Screenshots failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Sample project

    private static func makeModel(photo: URL, rain: URL, piano: URL) -> EditorModel {
        let m = EditorModel()
        m.setImage(photo)
        m.setDuration(8 * 3600)

        var a = AudioClip(url: rain, name: "Rain on Window", sourceDuration: 60, inPoint: 0, outPoint: 60,
                          start: 0, length: 8 * 3600, lane: 0)
        a.loop = true
        a.fadeIn = 8
        a.fadeOut = 30
        a.volume = 0.85
        a.normalize()

        var b = AudioClip(url: piano, name: "Soft Piano", sourceDuration: 45, inPoint: 0, outPoint: 45,
                          start: 1200, length: 5 * 3600, lane: 1)
        b.loop = true
        b.fadeIn = 20
        b.fadeOut = 60
        b.volume = 0.6
        b.normalize()

        m.project.clips = [a, b]
        m.playhead = 2400
        return m
    }

    // MARK: - Capture

    private static func capture<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) async throws {
        let controller = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentViewController: controller)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 2_500_000_000)  // layout, thumbnails, waveforms
        defer { window.close() }

        guard let image = snapshot(window) else { throw AppError("Couldn’t capture \(url.lastPathComponent)") }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AppError("Couldn’t write \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw AppError("Couldn’t write \(url.lastPathComponent)") }
        print("  captured \(url.lastPathComponent) \(image.width)×\(image.height)")
    }

    /// The whole window including title bar and toolbar when possible, otherwise just its content.
    private static func snapshot(_ window: NSWindow) -> CGImage? {
        let id = CGWindowID(window.windowNumber)
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]),
           cg.width > 100, cg.height > 100 {
            return cg
        }
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    // MARK: - Sample media

    /// A 3:2 landscape: sunset sky, mountains and a lake.
    private static func makePhoto(_ url: URL) throws {
        let w = 3000, h = 2000
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw AppError("ctx") }
        let W = CGFloat(w), H = CGFloat(h)
        func c(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

        let sky = CGGradient(colorsSpace: space,
                             colors: [c(0.98, 0.72, 0.45), c(0.93, 0.45, 0.45), c(0.35, 0.25, 0.55), c(0.10, 0.12, 0.30)] as CFArray,
                             locations: [0, 0.3, 0.65, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: H * 0.45), end: CGPoint(x: 0, y: H), options: [])
        ctx.setFillColor(c(0.99, 0.9, 0.6))
        ctx.fillEllipse(in: CGRect(x: W * 0.62, y: H * 0.5, width: 380, height: 380))

        func ridge(_ base: CGFloat, _ amp: CGFloat, _ color: CGColor, _ phase: Double) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= W {
                let y = base + amp * CGFloat(sin(Double(x) / 430 + phase) * 0.6 + sin(Double(x) / 150 + phase * 2) * 0.25)
                path.addLine(to: CGPoint(x: x, y: y))
                x += 20
            }
            path.addLine(to: CGPoint(x: W, y: 0))
            path.closeSubpath()
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ridge(H * 0.52, 260, c(0.42, 0.30, 0.50), 0.4)
        ridge(H * 0.45, 230, c(0.26, 0.20, 0.38), 2.1)
        ridge(H * 0.38, 150, c(0.14, 0.13, 0.26), 4.0)

        let lake = CGGradient(colorsSpace: space, colors: [c(0.08, 0.10, 0.22), c(0.55, 0.38, 0.50)] as CFArray, locations: [0, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H * 0.34))
        ctx.drawLinearGradient(lake, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H * 0.34), options: [])
        ctx.setFillColor(CGColor(srgbRed: 0.99, green: 0.9, blue: 0.6, alpha: 0.35))
        ctx.fillEllipse(in: CGRect(x: W * 0.62 + 40, y: H * 0.05, width: 300, height: 90))
        ctx.restoreGState()

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw AppError("image") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw AppError("png") }
    }

    private enum Kind { case rain, piano }

    private static func makeAudio(_ url: URL, seconds: Double, kind: Kind) throws {
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
              let ch = buffer.floatChannelData else { throw AppError("buffer") }
        buffer.frameLength = frames

        var seed: UInt64 = 12345
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFF) / 32768 - 1
        }
        let notes: [Double] = [261.63, 329.63, 392.0, 329.63, 440.0, 392.0, 329.63, 293.66]
        var lowpass: Float = 0
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            var s: Float = 0
            switch kind {
            case .rain:
                lowpass += 0.35 * (noise() - lowpass)
                let swell = 0.55 + 0.35 * sin(t * 0.35) + 0.1 * sin(t * 1.7)
                s = lowpass * Float(swell) * 0.6
            case .piano:
                let beat = 1.5
                let n = Int(t / beat)
                let local = t - Double(n) * beat
                let f = notes[n % notes.count]
                let envelope = exp(-local * 2.2)
                let tone = sin(2 * Double.pi * f * local) + 0.4 * sin(4 * Double.pi * f * local) + 0.15 * sin(6 * Double.pi * f * local)
                s = Float(envelope * 0.5 * tone / 1.5)
            }
            ch[0][i] = s
            ch[1][i] = s
        }
        try file.write(from: buffer)
    }
}
