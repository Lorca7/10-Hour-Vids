import Foundation
import AppKit

let arguments = CommandLine.arguments

// `--self-test` renders a few videos headlessly and checks them (used by CI).
// `--self-test --long` also renders a full hour to measure speed.
// `--screenshots <dir>` saves PNGs of the interface with a sample project.
if arguments.contains("--self-test") {
    let long = arguments.contains("--long")
    Task.detached {
        let ok = await SelfTest.run(long: long)
        exit(ok ? 0 : 1)
    }
    RunLoop.main.run()
} else if let index = arguments.firstIndex(of: "--screenshots") {
    let dir = index + 1 < arguments.count ? arguments[index + 1] : "screenshots"
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
        let ok = await Screenshots.run(into: URL(fileURLWithPath: dir))
        exit(ok ? 0 : 1)
    }
    app.run()
} else {
    TenHourVidsApp.main()
}
