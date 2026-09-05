import AppKit
import ScreenCaptureKit

private func screenCapturePermissionIsGranted() async -> Bool {
    if CGPreflightScreenCaptureAccess() {
        return true
    }
    do {
        _ = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true
        )
        return true
    } catch {
        return false
    }
}

private func screenIsLocked() -> Bool {
    (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
}

if CommandLine.arguments.contains("--self-test") {
    await SelfTest.run()
    exit(EXIT_SUCCESS)
}

#if REARVIEW_DOCUMENTATION
if CommandLine.arguments.contains("--documentation") {
    let statusPath = CommandLine.arguments.first(where: {
        $0.hasPrefix("--documentation-status-file=")
    }).map { String($0.dropFirst("--documentation-status-file=".count)) }
    func writeDocumentationStatus(_ message: String) {
        guard let statusPath else { return }
        try? message.write(
            to: URL(fileURLWithPath: statusPath), atomically: true, encoding: .utf8
        )
    }
    do {
        try await DocumentationRunner.run(arguments: CommandLine.arguments)
        writeDocumentationStatus("success\n")
        exit(EXIT_SUCCESS)
    } catch {
        let message = "Documentation build failed: \(error.localizedDescription)"
        writeDocumentationStatus(message + "\n")
        fputs("\(message)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
#endif

if CommandLine.arguments.contains("--check-screen-permission") {
    if screenIsLocked() {
        if let outputPath = CommandLine.arguments.first(where: {
            $0.hasPrefix("--screen-permission-output=")
        }) {
            let path = String(outputPath.dropFirst("--screen-permission-output=".count))
            try? "locked\n".write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        }
        fputs(
            "Screen capture is unavailable while the macOS screen is locked. Unlock the session and retry.\n",
            stderr
        )
        exit(3)
    }
    let granted = await screenCapturePermissionIsGranted()
    if let outputPath = CommandLine.arguments.first(where: {
        $0.hasPrefix("--screen-permission-output=")
    }) {
        let path = String(outputPath.dropFirst("--screen-permission-output=".count))
        let value = granted ? "granted\n" : "denied\n"
        try? value.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }
    if granted {
        print("Screen capture permission: granted (ScreenCaptureKit probe)")
        exit(EXIT_SUCCESS)
    }
    fputs(
        "Screen capture permission: denied. 시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 Rearview를 허용한 뒤 앱을 다시 실행하세요.\n",
        stderr
    )
    exit(2)
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
