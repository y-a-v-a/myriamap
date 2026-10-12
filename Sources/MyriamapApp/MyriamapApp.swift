import AppKit
import SwiftUI

@main
struct MyriamapApp: App {
    @State private var model = MapModel()

    init() {
        // Launched with `swift run` there is no bundle: still behave as a
        // regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Myriamap") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1500, height: 860)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Back to Now") { model.timeOffset = 0 }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Toggle("Day and Night", isOn: $model.display.night)
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Toggle("Cut Edges", isOn: $model.display.cuts)
                    .keyboardShortcut("k", modifiers: [.command, .option])
            }
        }
    }
}
