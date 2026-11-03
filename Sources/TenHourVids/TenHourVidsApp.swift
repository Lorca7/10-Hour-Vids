import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct TenHourVidsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("10 Hour Vids", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .defaultSize(width: 1320, height: 860)
        .commands { AppCommands(model: model) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: EditorModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project") { model.newProject() }
                .keyboardShortcut("n")
            Button("Open Project…") { model.openProjectPanel() }
                .keyboardShortcut("o")
            Divider()
            Button("Import Photo…") { model.importImagePanel() }
                .keyboardShortcut("i")
            Button("Add Audio…") { model.addAudioPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Project") { model.saveProject() }
                .keyboardShortcut("s")
            Button("Save Project As…") { model.saveProject(as: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Export Video for YouTube…") { model.showExport = true }
                .keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }
                .keyboardShortcut("z")
                .disabled(!model.canUndo)
            Button("Redo") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
        }
        CommandMenu("Timeline") {
            Button(model.isPlaying ? "Pause  (Space)" : "Play  (Space)") { model.togglePlay() }
            Button("Split Clip at Playhead") { model.splitAtPlayhead() }
                .keyboardShortcut("b")
            Button("Delete Selected Clip  (⌫)") { model.deleteSelection() }
                .disabled(model.selectedClip == nil)
            Divider()
            Button("Match Video Length to Audio") { model.matchAudioLength() }
                .disabled(model.project.clips.isEmpty)
            Divider()
            Button("Zoom In") { model.zoom(by: 1.5) }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.zoom(by: 1 / 1.5) }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { model.zoomToFit() }
                .keyboardShortcut("0")
        }
    }
}
