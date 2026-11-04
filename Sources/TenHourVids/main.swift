import Foundation

// `--self-test` renders a few videos headlessly and checks them (used by CI).
// `--self-test --long` also renders a full hour to measure speed.
if CommandLine.arguments.contains("--self-test") {
    let long = CommandLine.arguments.contains("--long")
    Task.detached {
        let ok = await SelfTest.run(long: long)
        exit(ok ? 0 : 1)
    }
    RunLoop.main.run()
} else {
    TenHourVidsApp.main()
}
