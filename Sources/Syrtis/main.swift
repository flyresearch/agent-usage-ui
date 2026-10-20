import AppKit

// Entry point. `--smoke` keeps the Phase 1 CLI bridge check available for CI,
// `--selftest` runs the TokenBarCore logic checks; anything else boots the
// menu-bar app (no storyboard, no .app bundle yet).

if CommandLine.arguments.contains("--fleet-login-roundtrip") {
    Task { @MainActor in
        _ = NSApplication.shared
        let result=AutostartService.registrationRoundTrip()
        if let data=try? JSONSerialization.data(withJSONObject:result,options:.sortedKeys),let output=String(data:data,encoding:.utf8) {print(output)}
        exit(result["test_ran"] as? Bool != true ? 2 : result["restoration_verified"] as? Bool == true ? 0:1)
    }
    dispatchMain()
}
if CommandLine.arguments.contains("--fleet-desktop-check") {
    Task { @MainActor in exit(await FleetProjectionCheck.desktopReadback()) }
    dispatchMain()
}
if let index=CommandLine.arguments.firstIndex(of:"--fleet-quota-history-preview"),CommandLine.arguments.count>index+1 {
    let path=CommandLine.arguments[index+1]
    Task { @MainActor in exit(FleetProjectionCheck.renderQuotaHistory(directory:path)) }
    dispatchMain()
}
if let index=CommandLine.arguments.firstIndex(of:"--fleet-source-preview"),CommandLine.arguments.count>index+1 {
    let path=CommandLine.arguments[index+1]
    Task { @MainActor in exit(FleetProjectionCheck.renderSources(directory:path)) }
    dispatchMain()
}
if let index=CommandLine.arguments.firstIndex(of:"--fleet-report-check"),CommandLine.arguments.count>index+1 {
    let path=CommandLine.arguments[index+1]
    Task {exit(await FleetProjectionCheck.runFile(path))}
    dispatchMain()
}
if CommandLine.arguments.contains("--fleet-projection-check") {
    Task {exit(await FleetProjectionCheck.run())}
    dispatchMain()
}
AppLanguage.prepareDirectRunResources()

if CommandLine.arguments.contains("--smoke") {
    exit(Smoke.run())
}
// Measurement lane, not a prototype: prints the current quota window's
// attributed totals and the scan timings the feature's performance comments
// quote. See `WindowProbe`.
if CommandLine.arguments.contains("--window-probe") {
    WindowProbe.run()
}
// Same kind of lane: times the synchronous quota refresh a window switch
// runs on the main actor. See `RefreshTimingProbe`.
if CommandLine.arguments.contains("--refresh-timing") {
    RefreshTimingProbe.start()
}
// Same kind of lane: when each part of the dashboard becomes drawable after
// a cold start, with the popover's tasks contending. See `LaunchTimelineProbe`.
if CommandLine.arguments.contains("--launch-timeline") {
    LaunchTimelineProbe.start()
}
if CommandLine.arguments.contains("--selftest") {
    // Some assertions compare against English UI copy, so on a non-English Mac
    // they would fail for the wrong reason. Say so instead of looking broken.
    if Bundle.main.preferredLocalizations.first != "en" {
        FileHandle.standardError.write(
            Data("warning: re-run with -AppleLanguages \"(en)\" (or `make selftest`) — string assertions expect English\n".utf8))
    }
    SelfTest.run()
}

if DemoData.ignoresLocalVisibility {
    DemoData.ignoreLocalVisibility()
}

// First launch after the Syrtis rename: move TokenBar.app to Syrtis.app and
// relaunch from there (exits on success). Before NSApplication, so nothing has
// loaded a resource through the old path yet.
if !FleetMode.enabled {BundleRename.runIfNeeded()}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
