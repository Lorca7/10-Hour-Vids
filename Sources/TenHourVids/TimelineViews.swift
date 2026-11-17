import SwiftUI
import AppKit

enum TL {
    static let header: CGFloat = 96
    static let ruler: CGFloat = 26
    static let photoRow: CGFloat = 58
    static let lane: CGFloat = 52
    static let gap: CGFloat = 6
    static let step: CGFloat = lane + gap
}

enum TrackRegion: Equatable {
    case video(Int)
    case photo
    case audio(Int)
}

/// Vertical layout of the tracks: video lanes (highest on top), the photo row, then audio lanes.
struct TimelineLayout {
    let videoLanes: Int
    let audioLanes: Int

    init(project: Project) {
        let maxVideo = project.clips.filter { $0.kind == .video }.map(\.lane).max() ?? -1
        let maxAudio = project.clips.filter { $0.kind == .audio }.map(\.lane).max() ?? -1
        videoLanes = max(1, maxVideo + 2)
        audioLanes = max(2, maxAudio + 2)
    }

    /// Video lane 0 sits just above the photo; higher lanes stack upwards and play on top.
    func videoY(_ i: Int) -> CGFloat { TL.gap + CGFloat(videoLanes - 1 - i) * TL.step }
    var photoY: CGFloat { TL.gap + CGFloat(videoLanes) * TL.step }
    func audioY(_ i: Int) -> CGFloat { photoY + TL.photoRow + TL.gap * 2 + CGFloat(i) * TL.step }
    var height: CGFloat { audioY(audioLanes) }
    func y(for clip: MediaClip) -> CGFloat { clip.kind == .video ? videoY(clip.lane) : audioY(clip.lane) }

    func region(atY y: CGFloat) -> TrackRegion {
        if y < photoY - TL.gap / 2 {
            let fromTop = max(0, Int(floor((y - TL.gap / 2) / TL.step)))
            return .video(max(0, videoLanes - 1 - fromTop))
        }
        if y < audioY(0) - TL.gap { return .photo }
        return .audio(max(0, Int(floor((y - audioY(0) + TL.gap / 2) / TL.step))))
    }
}

struct TimelinePanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var waveforms: WaveformStore
    @ObservedObject var thumbnails: ThumbnailStore

    var body: some View {
        let layout = TimelineLayout(project: model.project)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: TL.header, height: TL.ruler)
                RulerView(model: model)
                    .frame(height: TL.ruler)
                    .frame(maxWidth: .infinity)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { model.timelineResized(geo.size.width) }
                                .onChange(of: geo.size.width) { _, width in model.timelineResized(width) }
                        }
                    )
            }
            Divider()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    TrackHeaders(layout: layout)
                    TracksArea(model: model, waveforms: waveforms, thumbnails: thumbnails, layout: layout)
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text("Drag clips to move · drag their edges to trim · swipe sideways or ⇧-scroll to pan · pinch or ⌘-scroll to zoom")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Slider(value: Binding(get: { model.visibleStart }, set: { model.scroll(to: $0) }),
                       in: 0...max(model.maxVisibleStart, 0.001))
                    .controlSize(.mini)
                    .frame(minWidth: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct TrackHeaders: View {
    let layout: TimelineLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<layout.videoLanes, id: \.self) { i in
                label("Video \(i + 1)", icon: "film")
                    .frame(height: TL.lane)
                    .offset(y: layout.videoY(i))
            }
            label("Photo", icon: "photo")
                .frame(height: TL.photoRow)
                .offset(y: layout.photoY)
            ForEach(0..<layout.audioLanes, id: \.self) { i in
                label("Audio \(i + 1)", icon: "waveform")
                    .frame(height: TL.lane)
                    .offset(y: layout.audioY(i))
            }
        }
        .frame(width: TL.header, height: layout.height, alignment: .topLeading)
    }

    private func label(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: TL.header - 10, alignment: .leading)
        .padding(.leading, 10)
    }
}

// MARK: - Ruler

struct RulerView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let pps = model.pixelsPerSecond
        let start = model.visibleStart
        let playhead = model.playhead
        let videoEnd = model.project.video.duration
        Canvas { ctx, size in
            let (major, divisions) = RulerView.tickInterval(pps)
            let minor = major / Double(divisions)
            let endTime = start + Double(size.width) / pps
            var i = Int(floor(start / minor))
            while Double(i) * minor <= endTime {
                let t = Double(i) * minor
                let x = CGFloat((t - start) * pps)
                let isMajor = i % divisions == 0
                let h: CGFloat = isMajor ? 10 : 4
                ctx.fill(Path(CGRect(x: x, y: size.height - h, width: 1, height: h)),
                         with: .color(.secondary.opacity(isMajor ? 0.8 : 0.45)))
                if isMajor {
                    ctx.draw(Text(Timecode.format(t)).font(.system(size: 10).monospacedDigit()).foregroundColor(.secondary),
                             at: CGPoint(x: x + 3, y: 3), anchor: .topLeading)
                }
                i += 1
            }
            // End of video marker
            let endX = CGFloat((videoEnd - start) * pps)
            ctx.fill(Path(CGRect(x: endX - 1, y: 0, width: 2, height: size.height)), with: .color(.blue.opacity(0.8)))
            // Playhead
            let px = CGFloat((playhead - start) * pps)
            var head = Path()
            head.move(to: CGPoint(x: px - 6, y: 0))
            head.addLine(to: CGPoint(x: px + 6, y: 0))
            head.addLine(to: CGPoint(x: px + 6, y: size.height - 8))
            head.addLine(to: CGPoint(x: px, y: size.height))
            head.addLine(to: CGPoint(x: px - 6, y: size.height - 8))
            head.closeSubpath()
            ctx.fill(head, with: .color(.red))
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in model.seek(to: model.time(atX: value.location.x)) }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): model.timelineHovered = true; model.hoverX = p.x
            case .ended: model.timelineHovered = false
            }
        }
        .help("Click or drag to move the playhead")
    }

    /// Picks a labelled tick spacing that keeps labels at least ~80 px apart.
    static func tickInterval(_ pps: Double) -> (Double, Int) {
        let candidates: [(Double, Int)] = [
            (1, 4), (2, 4), (5, 5), (10, 5), (15, 3), (30, 6), (60, 4), (120, 4), (300, 5),
            (600, 5), (900, 3), (1800, 6), (3600, 4), (7200, 4),
        ]
        for c in candidates where c.0 * pps >= 80 { return c }
        return (7200, 4)
    }
}

// MARK: - Tracks

struct TracksArea: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var waveforms: WaveformStore
    @ObservedObject var thumbnails: ThumbnailStore
    let layout: TimelineLayout
    @State private var dropTargeted = false

    var body: some View {
        let width = model.timelineWidth
        let height = layout.height
        let videoEndX = model.x(for: model.project.video.duration)
        let hasVideo = model.project.clips.contains { $0.kind == .video }
        let hasAudio = model.project.clips.contains { $0.kind == .audio }
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: width, height: height)
            ForEach(0..<layout.videoLanes, id: \.self) { i in
                Rectangle().fill(Color.purple.opacity(0.05))
                    .frame(width: width, height: TL.lane)
                    .offset(y: layout.videoY(i))
            }
            Rectangle().fill(Color.primary.opacity(0.05))
                .frame(width: width, height: TL.photoRow)
                .offset(y: layout.photoY)
            ForEach(0..<layout.audioLanes, id: \.self) { i in
                Rectangle().fill(Color.primary.opacity(0.05))
                    .frame(width: width, height: TL.lane)
                    .offset(y: layout.audioY(i))
            }
            if videoEndX < width {
                Rectangle().fill(Color.black.opacity(0.28))
                    .frame(width: width - max(0, videoEndX), height: height)
                    .offset(x: max(0, videoEndX))
                    .allowsHitTesting(false)
            }
            if !hasVideo {
                hint("Drop video clips here — they play over the photo")
                    .frame(width: width, height: TL.lane)
                    .offset(y: layout.videoY(0))
            }
            if !hasAudio {
                hint("Drop music or other audio files here")
                    .frame(width: width, height: TL.lane)
                    .offset(y: layout.audioY(0))
            }
            PhotoBarView(model: model, y: layout.photoY)
            ForEach(model.project.clips) { clip in
                ClipView(model: model, waveforms: waveforms, thumbnails: thumbnails, clip: clip, y: layout.y(for: clip))
            }
            Rectangle().fill(Color.red)
                .frame(width: 1.5, height: height)
                .offset(x: model.x(for: model.playhead) - 0.75)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .coordinateSpace(name: "tracks")
        .onTapGesture(coordinateSpace: .local) { location in
            model.selection = nil
            model.seek(to: model.time(atX: location.x))
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): model.timelineHovered = true; model.hoverX = p.x
            case .ended: model.timelineHovered = false
            }
        }
        .dropDestination(for: URL.self) { urls, location in
            let t = max(0, model.time(atX: location.x))
            switch layout.region(atY: location.y) {
            case .video(let lane): return model.handleDrop(urls, time: t, videoLane: lane)
            case .audio(let lane): return model.handleDrop(urls, time: t, audioLane: lane)
            case .photo: return model.handleDrop(urls, time: t)
            }
        } isTargeted: { dropTargeted = $0 }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
    }
}

struct EdgeHandle: View {
    var active: Bool

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 10)
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(active ? 0.95 : 0.5))
                    .frame(width: 3)
                    .padding(.vertical, 12)
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

/// A small label that stays readable on any clip colour.
struct ClipLabel: View {
    let icon: String
    let text: String
    var loop = false

    var body: some View {
        HStack(spacing: 3) {
            if loop { Image(systemName: "repeat") }
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        .padding(4)
    }
}

/// The photo row: always runs the whole length of the video and shows wherever no video clip covers it.
struct PhotoBarView: View {
    @ObservedObject var model: EditorModel
    let y: CGFloat
    @State private var origin: Double?

    var body: some View {
        let width = model.timelineWidth
        let rawX0 = model.x(for: 0)
        let rawX1 = model.x(for: model.project.video.duration)
        let x0 = max(rawX0, -8)
        let x1 = min(rawX1, width + 8)
        let w = max(0, x1 - x0)
        let selected = model.selection == .video
        let thumbnail = model.previewImage
        let shift = x0 - rawX0

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.5))
            if let thumbnail {
                Canvas { ctx, size in
                    let tileH = size.height
                    let tileW = tileH * 16 / 9
                    let image = ctx.resolve(Image(nsImage: thumbnail))
                    var k = floor(shift / tileW)
                    while k * tileW - shift < size.width {
                        ctx.draw(image, in: CGRect(x: k * tileW - shift, y: 0, width: tileW, height: tileH))
                        k += 1
                    }
                }
                .opacity(0.6)
            }
            ClipLabel(icon: "photo",
                      text: (model.project.imageURL?.lastPathComponent ?? "No photo yet — drop one anywhere")
                        + " · " + Timecode.format(model.project.video.duration))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.white : Color.blue, lineWidth: selected ? 2 : 1)
        }
        .frame(width: w, height: TL.photoRow, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .trailing) {
            if rawX1 <= width + 8 {
                EdgeHandle(active: selected)
                    .help("Drag to change the video length")
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("tracks"))
                            .onChanged { value in
                                if origin == nil {
                                    origin = model.project.video.duration
                                    model.checkpoint()
                                    model.selection = .video
                                }
                                if let origin {
                                    model.dragDuration(origin: origin,
                                                       delta: Double(value.translation.width) / model.pixelsPerSecond)
                                }
                            }
                            .onEnded { _ in origin = nil }
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .video }
        .offset(x: x0, y: y)
        .opacity(w > 0 ? 1 : 0)
    }
}

/// An audio clip (green, with its waveform) or a video clip (purple, with a filmstrip).
struct ClipView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var waveforms: WaveformStore
    @ObservedObject var thumbnails: ThumbnailStore
    let clip: MediaClip
    let y: CGFloat
    @State private var origin: MediaClip?

    var body: some View {
        let width = model.timelineWidth
        let rawX0 = model.x(for: clip.start)
        let rawX1 = model.x(for: clip.end)
        let x0 = max(rawX0, -8)
        let x1 = min(rawX1, width + 8)
        let w = max(0, x1 - x0)
        let selected = model.selection == .clip(clip.id)
        let pps = model.pixelsPerSecond
        let visibleStart = model.visibleStart
        let isVideo = clip.kind == .video
        let tint = isVideo ? Color.purple : Color.green
        let peaks = isVideo ? nil : waveforms.peaks[clip.url]
        let frames = isVideo ? (thumbnails.thumbnails[clip.url] ?? []) : []
        let clip = self.clip

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(tint.opacity(selected ? 0.65 : 0.45))
            if isVideo {
                Canvas { ctx, size in
                    guard !frames.isEmpty else { return }
                    let tileW = size.height * 16 / 9
                    let shift = x0 - rawX0
                    var k = floor(shift / tileW)
                    while k * tileW - shift < size.width {
                        let t = min(clip.start + Double(k * tileW + tileW / 2) / pps, clip.end - 0.001)
                        let source = clip.sourceTime(at: t)
                        var best = frames[0]
                        for f in frames where abs(f.time - source) < abs(best.time - source) { best = f }
                        ctx.draw(Image(nsImage: best.image), in: CGRect(x: k * tileW - shift, y: 0, width: tileW, height: size.height))
                        k += 1
                    }
                }
                .opacity(0.75)
            }
            Canvas { ctx, size in
                // Loop boundaries
                if clip.loop {
                    for segment in clip.segments() where segment.timelineStart > clip.start + 0.001 {
                        let x = CGFloat((segment.timelineStart - visibleStart) * pps) - x0
                        if x >= 0 && x <= size.width {
                            ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 2, height: size.height)),
                                     with: .color(.white.opacity(0.55)))
                        }
                    }
                }
                guard let peaks, !peaks.isEmpty else { return }
                let rate = WaveformStore.peaksPerSecond
                let span = max(1, Int(rate / pps))
                let step = max(1, span / 24)
                let mid = size.height * 0.6
                let amplitude = size.height * 0.36
                var path = Path()
                var column: CGFloat = 0
                while column < size.width {
                    let t = visibleStart + Double(x0 + column) / pps
                    let index = Int(clip.sourceTime(at: t) * rate)
                    var peak: Float = 0
                    var j = 0
                    while j < span {
                        let k = index + j
                        if k >= 0 && k < peaks.count { peak = max(peak, peaks[k]) }
                        j += step
                    }
                    let h = max(0.5, CGFloat(peak) * amplitude * CGFloat(clip.gain(at: t)))
                    path.addRect(CGRect(x: column, y: mid - h, width: 1, height: h * 2))
                    column += 1
                }
                ctx.fill(path, with: .color(.white.opacity(0.75)))
            }
            ClipLabel(icon: isVideo ? "film" : "waveform", text: clip.name, loop: clip.loop)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(selected ? Color.white : tint, lineWidth: selected ? 2 : 1)
        }
        .frame(width: w, height: TL.lane, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            if rawX0 >= -8 { trimHandle(.left, selected: selected) }
        }
        .overlay(alignment: .trailing) {
            if rawX1 <= width + 8 { trimHandle(.right, selected: selected) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = .clip(clip.id) }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("tracks"))
                .onChanged { value in
                    if origin == nil {
                        origin = clip
                        model.checkpoint()
                        model.selection = .clip(clip.id)
                    }
                    guard let origin else { return }
                    // Video lanes are stacked upwards, audio lanes downwards.
                    let rows = Int((value.translation.height / TL.step).rounded())
                    model.moveClip(clip.id, origin: origin,
                                   deltaTime: Double(value.translation.width) / model.pixelsPerSecond,
                                   deltaLanes: isVideo ? -rows : rows)
                }
                .onEnded { _ in
                    origin = nil
                    model.finishMove(clip.id)
                }
        )
        .offset(x: x0, y: y)
        .opacity(w > 0 ? 1 : 0)
    }

    private func trimHandle(_ edge: TrimEdge, selected: Bool) -> some View {
        EdgeHandle(active: selected)
            .help(edge == .left ? "Drag to trim the start" : "Drag to trim the end (or extend a looped clip)")
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("tracks"))
                    .onChanged { value in
                        if origin == nil {
                            origin = clip
                            model.checkpoint()
                            model.selection = .clip(clip.id)
                        }
                        guard let origin else { return }
                        model.trimClip(clip.id, edge: edge, origin: origin,
                                       delta: Double(value.translation.width) / model.pixelsPerSecond)
                    }
                    .onEnded { _ in origin = nil }
            )
    }
}
