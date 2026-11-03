import SwiftUI
import AppKit

extension Color {
    init(_ c: RGBColor) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1) }
}

extension RGBColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}

struct ContentView: View {
    @ObservedObject var model: EditorModel
    @State private var dropTargeted = false

    var body: some View {
        VSplitView {
            HStack(spacing: 0) {
                PreviewPane(model: model)
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView(model: model)
                    .frame(width: 310)
            }
            .frame(minHeight: 280, idealHeight: 430)

            VStack(spacing: 0) {
                TransportBar(model: model)
                Divider()
                TimelinePanel(model: model, waveforms: model.waveforms)
            }
            .frame(minHeight: 240, idealHeight: 320)
        }
        .navigationTitle(model.windowTitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.importImagePanel() } label: { Label("Photo", systemImage: "photo.badge.plus") }
                    .help("Choose the photo for the video (⌘I)")
                Button { model.addAudioPanel() } label: { Label("Add Audio", systemImage: "music.note.list") }
                    .help("Add music or audio files (⇧⌘I)")
                Button { model.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export an MP4 for YouTube (⌘E)")
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 4)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(model: model)
        }
        .alert("Heads up",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { model.installEventMonitors() }
    }
}

// MARK: - Preview

struct PreviewPane: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ZStack {
            Color(white: 0.11)
            ZStack {
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Rectangle().fill(Color(model.project.video.background))
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 44))
                        Text("Drag & drop a photo here")
                            .font(.title3.weight(.semibold))
                        Text("Then drop music or audio files onto the timeline below.")
                            .font(.callout)
                            .opacity(0.8)
                        Button("Choose Photo…") { model.importImagePanel() }
                            .controlSize(.large)
                            .padding(.top, 4)
                    }
                    .foregroundStyle(.white)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(18)
                    )
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Text("\(Timecode.format(model.playhead, tenths: true)) / \(Timecode.format(model.project.video.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
            .shadow(radius: 8)
            .padding(18)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .video }
    }
}

// MARK: - Transport

struct TransportBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Button { model.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                .help("Go to start (Home)")
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help("Play / pause (Space)")
            Button { model.seek(to: model.project.video.duration) } label: { Image(systemName: "forward.end.fill") }
                .help("Go to end (End)")

            Text("\(Timecode.format(model.playhead, tenths: true)) / \(Timecode.format(model.project.video.duration))")
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 170, alignment: .leading)

            Divider().frame(height: 18)

            Button { model.splitAtPlayhead() } label: { Label("Split", systemImage: "scissors") }
                .help("Split the audio clip at the playhead (⌘B)")
            Button { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .disabled(model.selectedClip == nil)
                .help("Delete the selected clip (Delete)")
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")

            Spacer(minLength: 12)

            Button { model.zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)")
            Slider(value: Binding(get: { log(model.pixelsPerSecond) },
                                  set: { model.setZoom(exp($0)) }),
                   in: log(model.minPixelsPerSecond)...log(EditorModel.maxPixelsPerSecond))
                .frame(width: 150)
                .controlSize(.small)
            Button { model.zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘=)")
            Button("Fit") { model.zoomToFit() }
                .help("Show the whole timeline (⌘0)")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let clip = model.selectedClip {
            ClipInspector(model: model, clip: clip).id(clip.id)
        } else {
            VideoInspector(model: model)
        }
    }
}

/// A text field for times like 1:30:00. Edits are applied on Return or when leaving the field.
struct TimecodeField: View {
    let title: String
    let value: Double
    /// Applies the typed value and returns the value actually used (after clamping).
    let onCommit: (Double) -> Double
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text("H:MM:SS"))
            .font(.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onSubmit(commit)
            .onAppear { text = Timecode.format(value, tenths: true) }
            .onChange(of: value) { _, v in text = Timecode.format(v, tenths: true) }
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        if let parsed = Timecode.parse(text) {
            text = Timecode.format(onCommit(parsed), tenths: true)
        } else {
            text = Timecode.format(value, tenths: true)
        }
    }
}

struct VideoInspector: View {
    @ObservedObject var model: EditorModel

    private let presets: [(String, Double)] = [
        ("1 minute", 60), ("5 minutes", 300), ("10 minutes", 600), ("30 minutes", 1800),
        ("1 hour", 3600), ("2 hours", 7200), ("3 hours", 10800), ("4 hours", 14400),
        ("8 hours", 28800), ("10 hours", 36000),
    ]

    var body: some View {
        Form {
            Section("Photo") {
                if let image = model.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(model.imageInfo.isEmpty ? "No photo yet. Drag one into the window." : model.imageInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(model.project.imageURL == nil ? "Choose Photo…" : "Replace…") { model.importImagePanel() }
                    if model.project.imageURL != nil {
                        Button("Remove") { model.removeImage() }
                    }
                }
            }

            Section("Video Length") {
                TimecodeField(title: "Length", value: model.project.video.duration) { v in
                    model.setDuration(v, refit: true)
                    return model.project.video.duration
                }
                Menu("Quick Lengths") {
                    ForEach(presets.indices, id: \.self) { i in
                        Button(presets[i].0) { model.setDuration(presets[i].1, refit: true) }
                    }
                }
                Button("Match Length to Audio") { model.matchAudioLength() }
                    .disabled(model.project.clips.isEmpty)
                Text("Anywhere from 1 minute to 10 hours. You can also drag the right edge of the video bar in the timeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Framing") {
                Picker("Photo", selection: Binding(get: { model.project.video.fitMode },
                                                   set: { model.setFitMode($0) })) {
                    ForEach(FitMode.allCases) { Text($0.label).tag($0) }
                }
                ColorPicker("Background colour",
                            selection: Binding(get: { Color(model.project.video.background) },
                                               set: { model.setBackground(RGBColor($0)) }),
                            supportsOpacity: false)
            }
        }
        .formStyle(.grouped)
    }
}

struct ClipInspector: View {
    @ObservedObject var model: EditorModel
    let clip: AudioClip

    private func binding(_ keyPath: WritableKeyPath<AudioClip, Double>) -> Binding<Double> {
        let id = clip.id
        return Binding(
            get: { model.clip(id)?[keyPath: keyPath] ?? 0 },
            set: { value in
                model.updateClip(id, coalescing: "\(id)-\(keyPath.hashValue)") { $0[keyPath: keyPath] = value }
            }
        )
    }

    var body: some View {
        let id = clip.id
        let fadeMax = max(0.1, min(30, clip.length / 2))
        Form {
            Section("Audio Clip") {
                Text(clip.name).font(.headline)
                Text("\(clip.url.lastPathComponent) · \(Timecode.format(clip.sourceDuration, tenths: true)) long")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Timing") {
                TimecodeField(title: "Starts at", value: clip.start) { v in
                    model.updateClip(id) { $0.start = v }
                    return model.clip(id)?.start ?? v
                }
                TimecodeField(title: "Length on timeline", value: clip.length) { v in
                    model.updateClip(id) { $0.length = v }
                    return model.clip(id)?.length ?? v
                }
                TimecodeField(title: "Starts from (in file)", value: clip.inPoint) { v in
                    model.updateClip(id) { c in
                        if c.loop {
                            c.inPoint = v
                        } else {
                            let end = c.inPoint + c.length
                            c.inPoint = v
                            c.length = end - v
                        }
                    }
                    return model.clip(id)?.inPoint ?? v
                }
                if clip.loop {
                    TimecodeField(title: "Loop back at (in file)", value: clip.outPoint) { v in
                        model.updateClip(id) { $0.outPoint = v }
                        return model.clip(id)?.outPoint ?? v
                    }
                }
            }

            Section("Sound") {
                LabeledContent("Volume") {
                    HStack {
                        Slider(value: binding(\.volume), in: 0...1)
                        Text("\(Int((clip.volume * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Fade in") {
                    HStack {
                        Slider(value: binding(\.fadeIn), in: 0...fadeMax)
                        Text(String(format: "%.1f s", clip.fadeIn))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Fade out") {
                    HStack {
                        Slider(value: binding(\.fadeOut), in: 0...fadeMax)
                        Text(String(format: "%.1f s", clip.fadeOut))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Looping") {
                Toggle("Loop this audio", isOn: Binding(get: { model.clip(id)?.loop ?? false },
                                                        set: { model.setLoop(id, $0) }))
                Button("Loop to End of Video") { model.fillToEnd(id) }
                    .disabled(clip.start >= model.project.video.duration)
                Text("A looped clip repeats until you stop it — drag its right edge as far as you like.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Split at Playhead") { model.splitAtPlayhead() }
                    Spacer()
                    Button("Delete Clip", role: .destructive) { model.deleteSelection() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Export

struct ExportSheet: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export for YouTube").font(.title2.weight(.semibold))
            switch model.exportState {
            case .idle:
                settings
            case .running(let progress, let phase, let started):
                running(progress: progress, phase: phase, started: started)
            case .finished(let url):
                finished(url)
            case .failed(let message):
                failed(message)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(model.exportState.isRunning)
    }

    private var settings: some View {
        let duration = model.project.video.duration
        let hasAudio = !model.project.clips.isEmpty
        let audioEnd = min(model.project.audioEnd, duration)
        let estimate = model.exportSettings.estimatedBytes(duration: duration, hasAudio: hasAudio)
        return VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Resolution", selection: $model.exportSettings.resolution) {
                    ForEach(ExportResolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: $model.exportSettings.fps) {
                    ForEach([24, 25, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Audio quality", selection: $model.exportSettings.audioBitrate) {
                    ForEach([128_000, 192_000, 256_000, 320_000], id: \.self) { Text("AAC \($0 / 1000) kbps").tag($0) }
                }
                LabeledContent("Length", value: Timecode.format(duration))
                LabeledContent("Format", value: "MP4 · H.264 · AAC 48 kHz stereo")
                LabeledContent("Approx. file size", value: Timecode.byteCount(estimate))
            }
            .formStyle(.grouped)

            if model.project.imageURL == nil {
                Label("No photo yet — the video will be a plain background colour.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !hasAudio {
                Label("No audio yet — the video will be silent.", systemImage: "speaker.slash")
                    .foregroundStyle(.secondary)
            } else if audioEnd < duration - 1 {
                Label("The audio ends at \(Timecode.format(audioEnd)); the rest of the video will be silent.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.showExport = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { model.chooseExportDestination() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func running(progress: Double, phase: String, started: Date) -> some View {
        let elapsed = Date().timeIntervalSince(started)
        let remaining = progress > 0.02 ? elapsed * (1 - progress) / progress : nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(phase)
            ProgressView(value: progress)
            HStack {
                Text("\(Int(progress * 100))%")
                Spacer()
                Text("Elapsed \(Timecode.format(elapsed))")
                if let remaining { Text("· about \(Timecode.format(remaining)) left") }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text("Your Mac won’t go to sleep while exporting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel Export") { model.cancelExport() }
            }
        }
    }

    private func finished(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Export complete", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                Text("File size: \(Timecode.byteCount(Double(size)))").font(.caption)
            }
            Text("Upload this file at studio.youtube.com. Videos longer than 15 minutes need a verified YouTube account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer()
                Button("Done") {
                    model.resetExport()
                    model.showExport = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Export failed", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message).textSelection(.enabled)
            HStack {
                Spacer()
                Button("Close") {
                    model.resetExport()
                    model.showExport = false
                }
                Button("Back to Settings") { model.resetExport() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
