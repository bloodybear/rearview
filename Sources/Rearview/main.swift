import AppKit
import ScreenCaptureKit

if CommandLine.arguments.contains("--self-test") {
    await SelfTest.run()
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--check-screen-permission") {
    if CGPreflightScreenCaptureAccess() {
        print("Screen capture permission: granted")
        exit(EXIT_SUCCESS)
    }
    do {
        _ = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        print("Screen capture permission: granted (ScreenCaptureKit probe)")
        exit(EXIT_SUCCESS)
    } catch {
        fputs(
            "Screen capture permission: denied. 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 Rearview를 허용한 뒤 앱을 다시 실행하세요.\n",
            stderr
        )
        exit(2)
    }
}

if CommandLine.arguments.contains("--layout-benchmark") {
    let lineCount = CommandLine.arguments.first(where: { $0.hasPrefix("--layout-lines=") })
        .flatMap { Int($0.dropFirst("--layout-lines=".count)) } ?? 200
    let iterations = CommandLine.arguments.first(where: { $0.hasPrefix("--layout-iterations=") })
        .flatMap { Int($0.dropFirst("--layout-iterations=".count)) }
        ?? NativeMirrorCompositeBenchmark.defaultIterations
    do {
        _ = NSApplication.shared
        let result = try NativeMirrorCompositeBenchmark.run(lineCount: lineCount, iterations: iterations)
        print("Native composite benchmark passed: lines=\(lineCount), iterations=\(iterations)")
        print(String(
            format: "mirrorComposite p50=%.3fms p95=%.3fms; opacityComposite p50=%.3fms p95=%.3fms",
            result.compositeP50Milliseconds, result.compositeP95Milliseconds,
            result.opacityP50Milliseconds, result.opacityP95Milliseconds
        ))
        print("Report: \(result.reportURL.path)")
        exit(EXIT_SUCCESS)
    } catch {
        fputs("Layout benchmark failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}

// Keep the menu-bar app single-instance even when its executable is launched
// directly from inside the app bundle instead of through Finder or `open`.
let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.bloodybear.rearview"
let currentProcessID = NSRunningApplication.current.processIdentifier
let anotherInstanceIsRunning = NSRunningApplication
    .runningApplications(withBundleIdentifier: bundleIdentifier)
    .contains { $0.processIdentifier != currentProcessID }
if anotherInstanceIsRunning {
    fputs("Rearview is already running.\n", stderr)
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
