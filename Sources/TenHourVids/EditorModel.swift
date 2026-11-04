import SwiftUI
import AppKit
import AVFoundation
import QuartzCore
import UniformTypeIdentifiers

enum Selection: Equatable {
    case video
    case clip(UUID)
}

enum TrimEdge { case left, right }

enum ExportState: Equatable {
    case idle
    case running(progress: Double, phase: String, started: Date)
    case finished(URL)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class EditorModel: ObservableObject {
    // MARK: Document
    @Published var project = Project() {
        didSet { projectDidChange(from: oldValue) }
    }
    @Published private(set) var projectURL: URL?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var imageInfo = ""

    // MARK: Editing
    @Published var selection: Selection?
    @Published var playhead: Double = 0
    @Published private(set) var isPlaying = false
    @Published var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    // MARK: Timeline view
    @Published var pixelsPerSecond: Double = 0.25
    @Published var visibleStart: Double = 0
    @Published private(set) var timelineWidth: CGFloat = 900
    var timelineHovered = false
    var hoverX: CGFloat = 0
    static let maxPixelsPerSecond: Double = 300

    // MARK: Export
    @Published var showExport = false
    @Published var exportSettings = ExportSettings()
    @Published private(set) var exportState: ExportState = .idle

    let waveforms = WaveformStore()

    private var sourceImage: CGImage?
    private var undoStack: [Project] = [] { didSet { canUndo = !undoStack.isEmpty } }
    private var redoStack: [Project] = [] { didSet { canRedo = !redoStack.isEmpty } }
    private var lastCheckpointKey: String?
    private var lastCheckpointTime = Date.distantPast
    private var didInitialFit = false
    private var monitors: [Any] = []

    private var player: AVPlayer?
    private var timer: Timer?
    private var clockHead: Double = 0
    private var clockStart: CFTimeInterval = 0
    private var audioGeneration = 0
    private var audioRestartTask: Task<Void, Never>?
    private var exporter: VideoExporter?

    static let projectType: UTType = UTType(filenameExtension: "thvproject", conformingTo: .json) ?? .json

    var windowTitle: String {
        projectURL?.deletingPathExtension().lastPathComponent ?? "10 Hour Vids"
    }

    var selectedClip: AudioClip? {
        if case .clip(let id) = selection { return clip(id) }
        return nil
    }

    func clip(_ id: UUID) -> AudioClip? { project.clips.first { $0.id == id } }

    // MARK: - Change handling

    private func projectDidChange(from old: Project) {
        if project.imageURL != old.imageURL {
            loadImage()
        } else if project.video.fitMode != old.video.fitMode || project.video.background != old.video.background {
            renderPreview()
        }
        if project.clips != old.clips {
            for c in project.clips { waveforms.request(c.url) }
            if isPlaying { scheduleAudioRestart() }
        } else if project.video.duration != old.video.duration, isPlaying {
            scheduleAudioRestart()
        }
        if playhead > project.video.duration { playhead = project.video.duration }
    }

    private func loadImage() {
        guard let url = project.imageURL else {
            sourceImage = nil
            imageInfo = ""
            renderPreview()
            return
        }
        do {
            sourceImage = try ImageLoader.load(url, maxPixel: 2400)
            if let size = ImageLoader.pixelSize(url) {
                imageInfo = "\(url.lastPathComponent) — \(size.width) × \(size.height)"
            } else {
                imageInfo = url.lastPathComponent
            }
        } catch {
            sourceImage = nil
            imageInfo = "Missing: \(url.lastPathComponent)"
            errorMessage = error.localizedDescription
        }
        renderPreview()
    }

    private func renderPreview() {
        guard let image = sourceImage,
              let cg = FrameRenderer.renderImage(image: image, width: 1280, height: 720,
                                                 mode: project.video.fitMode, background: project.video.background)
        else {
            previewImage = nil
            return
        }
        previewImage = NSImage(cgImage: cg, size: NSSize(width: 1280, height: 720))
    }

    // MARK: - Undo

    /// Saves the current state for undo. Calls with the same `key` within a moment of each other
    /// (e.g. while dragging a slider) are merged into one undo step.
    func checkpoint(coalescing key: String? = nil) {
        let now = Date()
        if let key, key == lastCheckpointKey, now.timeIntervalSince(lastCheckpointTime) < 1.5 {
            lastCheckpointTime = now
            return
        }
        lastCheckpointKey = key
        lastCheckpointTime = now
        undoStack.append(project)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        lastCheckpointKey = nil
        project = previous
        validateSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        lastCheckpointKey = nil
        project = next
        validateSelection()
    }

    private func validateSelection() {
        if case .clip(let id) = selection, clip(id) == nil { selection = nil }
    }

    // MARK: - Photo

    func setImage(_ url: URL) {
        checkpoint()
        project.imageURL = url
        selection = .video
    }

    func removeImage() {
        guard project.imageURL != nil else { return }
        checkpoint()
        project.imageURL = nil
    }

    func importImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the photo for your video"
        if panel.runModal() == .OK, let url = panel.url { setImage(url) }
    }

    // MARK: - Audio import

    func addAudioPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose music or audio files"
        if panel.runModal() == .OK { addAudio(panel.urls) }
    }

    /// Adds audio files to the timeline one after another, starting at `time`
    /// (default: after the last clip in the lane).
    func addAudio(_ urls: [URL], at time: Double? = nil, lane: Int? = nil) {
        guard !urls.isEmpty else { return }
        Task { await addAudioAsync(urls, at: time, lane: lane) }
    }

    private func addAudioAsync(_ urls: [URL], at time: Double?, lane: Int?) async {
        let targetLane = lane ?? 0
        var t = time ?? (project.clips.filter { $0.lane == targetLane }.map(\.end).max() ?? 0)
        var added: [AudioClip] = []
        var failures: [String] = []
        for url in urls {
            do {
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                guard !tracks.isEmpty else { throw AppError("No audio track") }
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > Limits.minClipLength else { throw AppError("Empty audio") }
                var clip = AudioClip(url: url, name: url.deletingPathExtension().lastPathComponent,
                                     sourceDuration: duration, inPoint: 0, outPoint: duration,
                                     start: max(0, t), length: duration, lane: targetLane)
                clip.normalize()
                clip.lane = freeLane(for: clip, among: project.clips + added, from: targetLane)
                added.append(clip)
                t = clip.end
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        if !added.isEmpty {
            checkpoint()
            project.clips.append(contentsOf: added)
            selection = .clip(added[added.count - 1].id)
        }
        if !failures.isEmpty {
            errorMessage = "These files don’t contain audio that macOS can read:\n" + failures.joined(separator: "\n")
        }
    }

    private func freeLane(for clip: AudioClip, among clips: [AudioClip], from lane: Int) -> Int {
        var candidate = clip
        var l = max(0, lane)
        while true {
            candidate.lane = l
            if !clips.contains(where: { $0.id != clip.id && $0.overlaps(candidate) }) { return l }
            l += 1
        }
    }

    /// Handles files dropped on the window or the timeline. Returns true if anything was used.
    @discardableResult
    func handleDrop(_ urls: [URL], time: Double? = nil, lane: Int? = nil) -> Bool {
        var images: [URL] = []
        var audio: [URL] = []
        for url in urls where url.isFileURL {
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { continue }
            if type.conforms(to: .image) {
                images.append(url)
            } else if type.conforms(to: .audiovisualContent) || type.conforms(to: .audio) {
                audio.append(url)
            }
        }
        if let image = images.first { setImage(image) }
        if !audio.isEmpty { addAudio(audio, at: time, lane: lane) }
        if images.isEmpty && audio.isEmpty {
            errorMessage = "Drop a photo (JPEG, PNG, HEIC…) or audio files (MP3, M4A, WAV, AIFF…)."
            return false
        }
        return true
    }

    // MARK: - Video length

    func setDuration(_ seconds: Double, checkpoint cp: Bool = true, refit: Bool = false) {
        let value = min(max(seconds.rounded(), Limits.minDuration), Limits.maxDuration)
        guard value != project.video.duration else { return }
        if cp { checkpoint() }
        project.video.duration = value
        if refit { zoomToFit() }
    }

    func matchAudioLength() {
        guard project.audioEnd > 0 else { return }
        setDuration(project.audioEnd.rounded(.up), refit: true)
    }

    func dragDuration(origin: Double, delta: Double) {
        let proposed = snapTime(origin + delta, excluding: nil, includeVideoEnd: false)
        setDuration(proposed, checkpoint: false)
    }

    func setFitMode(_ mode: FitMode) {
        guard mode != project.video.fitMode else { return }
        checkpoint()
        project.video.fitMode = mode
    }

    func setBackground(_ color: RGBColor) {
        guard color != project.video.background else { return }
        checkpoint(coalescing: "background")
        project.video.background = color
    }

    // MARK: - Clip editing

    func updateClip(_ id: UUID, checkpoint cp: Bool = true, coalescing key: String? = nil, _ body: (inout AudioClip) -> Void) {
        guard let index = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var c = project.clips[index]
        body(&c)
        c.normalize()
        guard c != project.clips[index] else { return }
        if cp { checkpoint(coalescing: key) }
        project.clips[index] = c
    }

    func moveClip(_ id: UUID, origin: AudioClip, deltaTime: Double, deltaLanes: Int) {
        let start = snapped(start: max(0, origin.start + deltaTime), length: origin.length, excluding: id)
        updateClip(id, checkpoint: false) { c in
            c.start = start
            c.lane = max(0, origin.lane + deltaLanes)
        }
    }

    /// After a drag, bumps a clip to a free lane if it landed on top of another clip.
    func finishMove(_ id: UUID) {
        guard let c = clip(id), project.clips.contains(where: { $0.id != id && $0.overlaps(c) }) else { return }
        let lane = freeLane(for: c, among: project.clips, from: c.lane)
        updateClip(id, checkpoint: false) { $0.lane = lane }
    }

    func trimClip(_ id: UUID, edge: TrimEdge, origin o: AudioClip, delta: Double) {
        let minLen = Limits.minClipLength
        updateClip(id, checkpoint: false) { c in
            switch edge {
            case .left:
                let target = snapTime(o.start + delta, excluding: id)
                let minD = o.loop ? -o.start : max(-o.start, -o.inPoint)
                let maxD = o.length - minLen
                let d = min(max(target - o.start, minD), maxD)
                c.start = o.start + d
                c.length = o.length - d
                if o.loop {
                    c.offset = AudioClip.wrap(o.offset + d, o.region)
                } else {
                    c.inPoint = o.inPoint + d
                }
            case .right:
                let target = snapTime(o.end + delta, excluding: id)
                let maxLen = o.loop ? Limits.maxDuration : o.sourceDuration - o.inPoint
                c.length = min(max(target - o.start, minLen), maxLen)
            }
        }
    }

    func setLoop(_ id: UUID, _ on: Bool) {
        updateClip(id) { c in
            if on {
                c.loop = true
            } else {
                c.inPoint = c.sourceTime(at: c.start)
                c.offset = 0
                c.loop = false
                c.length = min(c.length, c.sourceDuration - c.inPoint)
            }
        }
    }

    /// Makes the clip loop until the end of the video.
    func fillToEnd(_ id: UUID) {
        guard let c = clip(id), c.start < project.video.duration - Limits.minClipLength else { return }
        let length = project.video.duration - c.start
        updateClip(id) { c in
            if c.region >= Limits.minLoopRegion || length > c.length { c.loop = true }
            c.length = length
        }
    }

    func splitAtPlayhead() {
        let p = playhead
        var targets: [UUID] = []
        if let c = selectedClip, c.split(at: p) != nil {
            targets = [c.id]
        } else {
            targets = project.clips.filter { $0.split(at: p) != nil }.map(\.id)
        }
        guard !targets.isEmpty else { NSSound.beep(); return }
        checkpoint()
        var clips = project.clips
        var lastRight: UUID?
        for id in targets {
            guard let i = clips.firstIndex(where: { $0.id == id }), let halves = clips[i].split(at: p) else { continue }
            clips[i] = halves.0
            clips.insert(halves.1, at: i + 1)
            lastRight = halves.1.id
        }
        project.clips = clips
        if let lastRight { selection = .clip(lastRight) }
    }

    func deleteSelection() {
        guard let c = selectedClip else { return }
        checkpoint()
        project.clips.removeAll { $0.id == c.id }
        selection = nil
    }

    // MARK: - Snapping

    private func snapPoints(excluding id: UUID?, includeVideoEnd: Bool) -> [Double] {
        var points: [Double] = [0, playhead]
        if includeVideoEnd { points.append(project.video.duration) }
        for c in project.clips where c.id != id {
            points.append(c.start)
            points.append(c.end)
        }
        return points
    }

    func snapTime(_ t: Double, excluding id: UUID?, includeVideoEnd: Bool = true) -> Double {
        let threshold = 8 / pixelsPerSecond
        var best = t
        var bestDistance = threshold
        for p in snapPoints(excluding: id, includeVideoEnd: includeVideoEnd) where abs(p - t) < bestDistance {
            best = p
            bestDistance = abs(p - t)
        }
        return best
    }

    private func snapped(start: Double, length: Double, excluding id: UUID) -> Double {
        let threshold = 8 / pixelsPerSecond
        var best = start
        var bestDistance = threshold
        for p in snapPoints(excluding: id, includeVideoEnd: true) {
            if abs(start - p) < bestDistance { best = p; bestDistance = abs(start - p) }
            if abs(start + length - p) < bestDistance { best = p - length; bestDistance = abs(start + length - p) }
        }
        return max(0, best)
    }

    // MARK: - Timeline geometry

    var totalLength: Double { max(project.video.duration, project.audioEnd) }
    var contentLength: Double { max(totalLength, Limits.minDuration) * 1.06 + 5 }
    var fitPixelsPerSecond: Double { Double(max(timelineWidth, 100)) / contentLength }
    var minPixelsPerSecond: Double { fitPixelsPerSecond * 0.5 }
    var maxVisibleStart: Double { max(0, contentLength - Double(timelineWidth) / pixelsPerSecond) }

    func x(for t: Double) -> CGFloat { CGFloat((t - visibleStart) * pixelsPerSecond) }
    func time(atX x: CGFloat) -> Double { visibleStart + Double(x) / pixelsPerSecond }

    func timelineResized(_ width: CGFloat) {
        guard width > 10, abs(width - timelineWidth) > 0.5 || !didInitialFit else { return }
        timelineWidth = width
        if !didInitialFit {
            didInitialFit = true
            zoomToFit()
        } else {
            clampScroll()
        }
    }

    func clampScroll() {
        visibleStart = min(max(0, visibleStart), maxVisibleStart)
    }

    func scroll(to start: Double) {
        visibleStart = start
        clampScroll()
    }

    func setZoom(_ pps: Double, anchorX: CGFloat? = nil) {
        let playheadX = x(for: playhead)
        let anchor = anchorX ?? ((playheadX >= 0 && playheadX <= timelineWidth) ? playheadX : timelineWidth / 2)
        let t = time(atX: anchor)
        pixelsPerSecond = min(max(pps, minPixelsPerSecond), Self.maxPixelsPerSecond)
        visibleStart = t - Double(anchor) / pixelsPerSecond
        clampScroll()
    }

    func zoom(by factor: Double, anchorX: CGFloat? = nil) {
        setZoom(pixelsPerSecond * factor, anchorX: anchorX)
    }

    func zoomToFit() {
        pixelsPerSecond = fitPixelsPerSecond
        visibleStart = 0
    }

    private func keepPlayheadVisible() {
        let px = x(for: playhead)
        if px > timelineWidth - 30 || px < 0 {
            visibleStart = playhead - Double(timelineWidth) * 0.1 / pixelsPerSecond
            clampScroll()
        }
    }

    // MARK: - Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        if playhead >= project.video.duration - 0.05 { playhead = 0 }
        isPlaying = true
        resetClock()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        restartAudio()
    }

    func pause() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
        audioRestartTask?.cancel()
        audioGeneration += 1
        player?.pause()
        player = nil
    }

    func seek(to t: Double) {
        playhead = min(max(0, t), project.video.duration)
        if isPlaying {
            resetClock()
            if let player {
                player.seek(to: CompositionBuilder.cm(playhead), toleranceBefore: .zero, toleranceAfter: .zero)
            } else {
                scheduleAudioRestart()
            }
        }
        keepPlayheadVisible()
    }

    private func resetClock() {
        clockHead = playhead
        clockStart = CACurrentMediaTime()
    }

    private func tick() {
        guard isPlaying else { return }
        let t = clockHead + (CACurrentMediaTime() - clockStart)
        if t >= project.video.duration {
            playhead = project.video.duration
            pause()
            return
        }
        playhead = t
        keepPlayheadVisible()
    }

    private func scheduleAudioRestart() {
        audioRestartTask?.cancel()
        audioRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.isPlaying else { return }
            self.resetClock()
            self.restartAudio()
        }
    }

    private func restartAudio() {
        audioGeneration += 1
        let generation = audioGeneration
        player?.pause()
        player = nil
        let clips = project.clips
        let limit = project.video.duration
        guard !clips.isEmpty else { return }
        Task { [weak self] in
            guard let built = try? await CompositionBuilder.build(clips: clips, limit: limit), built.duration > 0 else { return }
            guard let self, self.isPlaying, generation == self.audioGeneration else { return }
            let item = AVPlayerItem(asset: built.composition)
            item.audioMix = built.audioMix
            let player = AVPlayer(playerItem: item)
            self.player = player
            let position = self.playhead
            _ = await player.seek(to: CompositionBuilder.cm(position), toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.isPlaying, generation == self.audioGeneration else { return }
            self.playhead = position
            self.resetClock()
            player.play()
        }
    }

    // MARK: - Keyboard, scroll wheel and pinch

    func installEventMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleKey(event) }
            return handled ? nil : event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleScroll(event) }
            return handled ? nil : event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] event in
            guard let self else { return event }
            let handled = MainActor.assumeIsolated { self.handleMagnify(event) }
            return handled ? nil : event
        }) { monitors.append(m) }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        if showExport { return false }
        if let window = event.window, window.firstResponder is NSText { return false }  // typing in a field
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlay()                                         // space
        case 51, 117: deleteSelection()                               // delete / forward delete
        case 123: seek(to: playhead - (shift ? 10 : 1))               // ←
        case 124: seek(to: playhead + (shift ? 10 : 1))               // →
        case 115: seek(to: 0)                                         // home
        case 119: seek(to: project.video.duration)                    // end
        default: return false
        }
        return true
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard timelineHovered else { return false }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let dy = event.scrollingDeltaY * scale
            guard dy != 0 else { return true }
            zoom(by: exp(Double(dy) * 0.01), anchorX: hoverX)
            return true
        }
        let dx = event.scrollingDeltaX * scale
        if dx != 0, abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) {
            scroll(to: visibleStart - Double(dx) / pixelsPerSecond)
            return true
        }
        return false
    }

    private func handleMagnify(_ event: NSEvent) -> Bool {
        guard timelineHovered else { return false }
        zoom(by: 1 + Double(event.magnification), anchorX: hoverX)
        return true
    }

    // MARK: - Projects

    func newProject() {
        pause()
        project = Project()
        undoStack = []
        redoStack = []
        projectURL = nil
        selection = nil
        playhead = 0
        zoomToFit()
    }

    func saveProject(as saveAs: Bool = false) {
        var url = projectURL
        if saveAs || url == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [Self.projectType]
            panel.nameFieldStringValue = (projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".thvproject"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }
        guard let url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
            projectURL = url
        } catch {
            errorMessage = "Couldn’t save the project: \(error.localizedDescription)"
        }
    }

    func openProjectPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            pause()
            project = loaded
            undoStack = []
            redoStack = []
            projectURL = url
            selection = nil
            playhead = 0
            zoomToFit()
            let missing = loaded.clips.map(\.url).filter { !FileManager.default.fileExists(atPath: $0.path) }
            if !missing.isEmpty {
                errorMessage = "Some audio files have moved or been deleted:\n"
                    + Set(missing.map(\.lastPathComponent)).sorted().joined(separator: "\n")
            }
        } catch {
            errorMessage = "Couldn’t open the project: \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    var suggestedExportName: String {
        if let projectURL { return projectURL.deletingPathExtension().lastPathComponent }
        if let imageURL = project.imageURL { return imageURL.deletingPathExtension().lastPathComponent }
        return "My Video"
    }

    func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedExportName + ".mp4"
        panel.message = "Save the video for uploading to YouTube"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let estimate = exportSettings.estimatedBytes(duration: project.video.duration, hasAudio: !project.clips.isEmpty)
        if let values = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage, Double(available) < estimate * 1.1 {
            exportState = .failed("Not enough free disk space. The video needs about \(Timecode.byteCount(estimate)) "
                                  + "but only \(Timecode.byteCount(Double(available))) is free on that disk.")
            return
        }
        startExport(to: url)
    }

    func startExport(to url: URL) {
        pause()
        let exporter = VideoExporter()
        self.exporter = exporter
        let project = self.project
        let settings = exportSettings
        exportState = .running(progress: 0, phase: "Preparing…", started: Date())
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Exporting video")
        Task { [weak self] in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await exporter.export(project: project, settings: settings, to: url) { fraction, phase in
                    Task { @MainActor [weak self] in
                        guard let self, case .running(_, _, let started) = self.exportState else { return }
                        self.exportState = .running(progress: fraction, phase: phase, started: started)
                    }
                }
                self?.exportState = .finished(url)
            } catch is CancellationError {
                self?.exportState = .idle
            } catch {
                self?.exportState = .failed(error.localizedDescription)
            }
            self?.exporter = nil
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }

    func resetExport() {
        if !exportState.isRunning { exportState = .idle }
    }
}
