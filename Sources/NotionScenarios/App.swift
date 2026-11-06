import AppKit
import SwiftUI
import NotionScenarioCore

@main
struct Main {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--request"), args.indices.contains(index + 1),
           let out = args.firstIndex(of: "--output"), args.indices.contains(out + 1) {
            do {
                let request = try JSONDecoder().decode(RunRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[index + 1])))
                let result = await ScenarioRunner().run(request, directory: URL(fileURLWithPath: args[out + 1])) { step in
                    if let data = try? JSONEncoder().encode(step) { FileHandle.standardError.write(data + Data([10])) }
                }
                exit(result.status == "verified" ? 0 : result.status == "partial" ? 2 : 3)
            } catch {
                FileHandle.standardError.write(Data("Native runner could not decode request: \(error)\n".utf8)); exit(3)
            }
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let model = ScenarioModel()
        let comparisonWindowController = ScreenshotComparisonWindowController()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Notion Screen Scenarios"
        window.contentView = NSHostingView(rootView: ScenarioView(model: model, comparisonWindowController: comparisonWindowController))
        let delegate = AppDelegate(); NSApp.delegate = delegate
        let menu = NSMenu(), appMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        appMenu.addItem(withTitle: "Quit Notion Scenarios", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(), editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit; menu.addItem(editItem)
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        window.makeKeyAndOrderFront(nil); NSApp.activate()
        model.locateRoot()
        NSApp.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct ScenarioButtonHoverHighlight: ViewModifier {
    var padding: CGFloat = 0
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isHovered && isEnabled ? 0.12 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(isHovered && isEnabled ? 0.22 : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private extension View {
    func scenarioHoverHighlight(padding: CGFloat = 0) -> some View {
        modifier(ScenarioButtonHoverHighlight(padding: padding))
    }

    func scenarioIconButtonHighlight() -> some View {
        padding(3)
            .frame(minWidth: 24, minHeight: 24)
            .scenarioHoverHighlight()
    }
}

private final class ScreenshotComparisonWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            close()
            return
        }
        super.sendEvent(event)
    }
}

@MainActor final class ScreenshotComparisonWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var displayedComparisonID: String?

    func show(saved: NSImage, applied: NSImage, model: ScenarioModel) {
        let comparisonID = [
            model.lastRunFixtureId,
            model.lastRunScenarioId,
            model.lastRunId,
            model.savedCaptureAt,
            model.screenshotCapturedAt
        ].joined(separator: "|")

        if let window {
            if displayedComparisonID != comparisonID {
                window.contentView = NSHostingView(rootView: makeContent(saved: saved, applied: applied, model: model))
                window.title = "Screenshot comparison · \(model.lastRunScenarioId)"
                displayedComparisonID = comparisonID
            }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let newWindow = ScreenshotComparisonWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1500, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.isReleasedWhenClosed = false
        newWindow.title = "Screenshot comparison · \(model.lastRunScenarioId)"
        newWindow.minSize = NSSize(width: 900, height: 600)
        newWindow.contentView = NSHostingView(rootView: makeContent(saved: saved, applied: applied, model: model))
        newWindow.delegate = self
        newWindow.center()
        window = newWindow
        displayedComparisonID = comparisonID
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeContent(saved: NSImage, applied: NSImage, model: ScenarioModel) -> ScreenshotComparisonWindowView {
        ScreenshotComparisonWindowView(
            savedImage: saved,
            appliedImage: applied,
            savedLabel: "Saved capture · v\(model.lastRunScenarioVersion ?? 0) · \(model.savedCaptureTimeLabel)",
            appliedLabel: "Latest apply · v\(model.lastRunScenarioVersion ?? 0) · \(model.screenshotTimeLabel)",
            comparison: model.screenshotComparison,
            savedCaptureDirectory: model.savedCaptureDirectory,
            latestApplyDirectory: model.runDirectory
        )
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, window === closingWindow else { return }
        window = nil
        displayedComparisonID = nil
    }
}
struct FixtureItem: Decodable, Identifiable { var id: String; var title: String?; var version: String }
struct Listing: Decodable { var fixtures: [FixtureItem]; var scenarios: [Scenario] }
private struct DeletedScenario {
    let id: String
    let name: String
    let rootURL: URL
    let fileURL: URL
    let contents: Data
    let wasSelected: Bool
    let token: UUID
}
@MainActor final class ScenarioModel: ObservableObject {
    @Published var root: URL?
    @Published var fixtures: [FixtureItem] = []
    @Published var scenarios: [Scenario] = []
    @Published var fixtureId = "layout-stress"
    @Published var selected: String?
    @Published var editor = ""
    @Published var savedEditor = ""
    @Published var stepResults: [StepResult] = []
    @Published var newId = ""
    @Published var busy = false
    @Published var messages = ""
    @Published var saveError = ""
    @Published private(set) var unsavedEditBlockPulse = 0
    @Published var summary = ""
    @Published var runStatus = ""
    @Published var image: NSImage?
    @Published var runDirectory: URL?
    @Published var lastRunOperation = ""
    @Published var lastRunFixtureId = ""
    @Published var lastRunScenarioId = ""
    @Published var lastRunScenarioVersion: Int?
    @Published var lastRunId = ""
    @Published var lastRunStartedAt = ""
    @Published var lastRunStatus = ""
    @Published var runErrorSummary = ""
    @Published var savedScenarioId: String?
    @Published var screenshotCapturedAt = ""
    @Published var savedCaptureDirectory: URL?
    @Published var savedCaptureImage: NSImage?
    @Published var savedCaptureAt = ""
    @Published var screenshotComparison = ""
    @Published var undoDeleteMessage: String?
    private var pendingDeletion: DeletedScenario?
    private var undoExpirationTask: Task<Void, Never>?
    var current: Scenario? { scenarios.first { $0.id == selected } }
    var hasUnsavedEditorChanges: Bool { editor != savedEditor }
    var unsavedEditorNotice: String {
        let scenarioName = current?.name ?? "the current scenario"
        return "Unsaved changes to \(scenarioName). Save or discard them before switching scenarios or capturing a new one."
    }
    @discardableResult
    func blockActionForUnsavedEditorChanges() -> Bool {
        guard hasUnsavedEditorChanges else { return false }
        unsavedEditBlockPulse &+= 1
        return true
    }
    var lastRunOperationLabel: String {
        switch lastRunOperation {
        case "apply": "Apply saved scenario"
        case "capture": "Capture as new scenario"
        default: lastRunOperation
        }
    }
    var lastRunTimeLabel: String { formatTimestamp(lastRunStartedAt) }
    var screenshotTimeLabel: String { formatTimestamp(screenshotCapturedAt) }
    var savedCaptureTimeLabel: String { formatTimestamp(savedCaptureAt) }
    private func formatTimestamp(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return value }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
    var newIdIssue: String? {
        guard !newId.isEmpty else { return nil }
        let scalars = Array(newId.unicodeScalars)
        let isAsciiLowerOrDigit: (UnicodeScalar) -> Bool = { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 122)
        }
        guard scalars.count <= 80 else { return "ID는 최대 80자까지 입력할 수 있습니다." }
        guard let first = scalars.first, isAsciiLowerOrDigit(first) else {
            return "ID는 소문자 영문 또는 숫자로 시작해야 합니다."
        }
        guard scalars.dropFirst().allSatisfy({ isAsciiLowerOrDigit($0) || $0.value == 45 }) else {
            return "ID에는 소문자 영문·숫자·하이픈만 사용할 수 있습니다."
        }
        if scenarios.contains(where: { $0.id == newId }) { return "이미 사용 중인 ID입니다. 다른 ID를 입력해 주세요." }
        return nil
    }
    var canUseNewId: Bool { !newId.isEmpty && newIdIssue == nil }
    func locateRoot() {
        if let i = CommandLine.arguments.firstIndex(of: "--root"), CommandLine.arguments.indices.contains(i + 1) {
            root = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        } else if let path = UserDefaults.standard.string(forKey: "fixtureRoot") { root = URL(fileURLWithPath: path) }
        else {
            var base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            for _ in 0..<7 {
                let candidate = base.appendingPathComponent("notion-fixtures")
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("fixture").path) { root = candidate; break }
                base.deleteLastPathComponent()
            }
        }
        if root != nil { reload(); loadLatestRun() }
    }
    func chooseRoot() {
        guard !blockActionForUnsavedEditorChanges() else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose the notion-fixtures folder containing the fixture CLI"
        if panel.runModal() == .OK, let url = panel.url {
            applyRoot(url)
        }
    }
    private func applyRoot(_ url: URL) {
        clearPendingDeletion()
        root = url
        UserDefaults.standard.set(url.path, forKey: "fixtureRoot")
        reload()
        loadLatestRun()
    }
    func select(_ id: String?) {
        selected = id
        saveError = ""
        guard let s = current else { editor = ""; savedEditor = ""; return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        editor = String(data: (try? encoder.encode(s)) ?? Data(), encoding: .utf8) ?? ""
        savedEditor = editor
    }
    func requestScenarioSelection(_ id: String?) {
        guard id != selected else { return }
        guard !blockActionForUnsavedEditorChanges() else { return }
        select(id)
    }
    func requestFixtureSelection(_ id: String) {
        guard id != fixtureId else { return }
        guard !blockActionForUnsavedEditorChanges() else { return }
        fixtureId = id
        select(nil)
    }
    func discardEditorChanges() {
        guard hasUnsavedEditorChanges else { return }
        editor = savedEditor
        saveError = ""
    }
    func reload(selecting requestedSelection: String? = nil) {
        command(["list", "--json"], resetProgress: false) { data in
            do {
                let listing = try JSONDecoder().decode(Listing.self, from: data)
                self.fixtures = listing.fixtures; self.scenarios = listing.scenarios
                if let requestedSelection, listing.scenarios.contains(where: { $0.id == requestedSelection }) {
                    self.select(requestedSelection)
                } else if let selected = self.selected {
                    if listing.scenarios.contains(where: { $0.id == selected }) {
                        if self.editor == self.savedEditor { self.select(selected) }
                    } else if self.editor == self.savedEditor {
                        self.select(nil)
                    }
                }
                if !self.fixtures.contains(where: { $0.id == self.fixtureId }) { self.fixtureId = self.fixtures.first?.id ?? "" }
            } catch { self.messages += "\n\(error)" }
        }
    }
    func loadLatestRun() {
        lastRunOperation = ""; lastRunFixtureId = ""; lastRunScenarioId = ""
        lastRunScenarioVersion = nil; lastRunId = ""; lastRunStartedAt = ""; lastRunStatus = ""
        runErrorSummary = ""
        savedScenarioId = nil; screenshotCapturedAt = ""
        savedCaptureDirectory = nil; savedCaptureImage = nil; savedCaptureAt = ""; screenshotComparison = ""
        runStatus = ""; stepResults = []; summary = ""; runDirectory = nil; image = nil
        guard let root,
              let directories = try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("runs"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return }
        for directory in directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let resultURL = directory.appendingPathComponent("result.json")
            let requestURL = directory.appendingPathComponent("request.json")
            guard let resultData = try? Data(contentsOf: resultURL),
                  let value = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  let requestData = try? Data(contentsOf: requestURL),
                  let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                  let operation = request["operation"] as? String,
                  ["apply", "capture"].contains(operation),
                  let status = value["status"] as? String, status != "running" else { continue }
            let requestedScenario = request["scenario"] as? [String: Any] ?? [:]
            lastRunOperation = operation
            lastRunFixtureId = value["fixtureId"] as? String ?? requestedScenario["fixtureId"] as? String ?? ""
            lastRunScenarioId = value["scenarioId"] as? String ?? requestedScenario["id"] as? String ?? ""
            lastRunScenarioVersion = value["scenarioVersion"] as? Int ?? requestedScenario["version"] as? Int
            lastRunId = value["runId"] as? String ?? directory.lastPathComponent
            lastRunStartedAt = value["startedAt"] as? String ?? ""
            lastRunStatus = status; runStatus = status
            runErrorSummary = userFacingError(value, request: request) ?? ""
            savedScenarioId = value["savedScenario"] as? String
            screenshotCapturedAt = (value["screenshot"] as? [String: Any])?["capturedAt"] as? String ?? ""
            if let steps = value["steps"], let encoded = try? JSONSerialization.data(withJSONObject: steps),
               let decoded = try? JSONDecoder().decode([StepResult].self, from: encoded) { stepResults = decoded }
            summary = String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? resultData, encoding: .utf8) ?? ""
            runDirectory = directory
            image = NSImage(contentsOf: directory.appendingPathComponent("screen.png"))
            loadSavedCaptureComparison()
            messages = "Loaded latest saved run: \(lastRunId)"
            return
        }
    }
    private func userFacingError(_ value: [String: Any], request: [String: Any]? = nil) -> String? {
        let captureWarnings = value["captureWarnings"] as? [String] ?? []
        if value["status"] as? String != "failed", !captureWarnings.isEmpty {
            return "Capture saved with warnings: " + captureWarnings.joined(separator: " ")
        }
        guard value["status"] as? String == "failed" else { return nil }
        let requestedScenario = request?["scenario"] as? [String: Any] ?? [:]
        let fixtureId = value["fixtureId"] as? String ?? requestedScenario["fixtureId"] as? String ?? "selected document"
        if let saveError = value["captureSaveError"] as? String {
            return "The screen was captured, but the scenario could not be saved: \(saveError)"
        }
        let steps = value["steps"] as? [[String: Any]] ?? []
        guard let failure = steps.first(where: { $0["status"] as? String == "failed" }) else {
            return "The scenario failed. See Progress & item results for details."
        }
        let code = failure["code"] as? String ?? ""
        let detail = failure["detail"] as? String ?? "The scenario failed. See Progress & item results for details."
        switch code {
        case "selected_document_not_found":
            return "Could not find selected document '\(fixtureId)' in a Notion window. This action only captures the selected document. Open that page and try again."
        case "notion_not_running":
            return "Notion desktop is not open. Open Notion and try again."
        case "target_window_focus_failed":
            return "The selected document '\(fixtureId)' was found, but its window could not be brought forward. Bring it to the front and try again."
        case "ambiguous_window":
            return "The selected document is open in multiple Notion windows. Close duplicate windows and try again."
        case "accessibility_permission":
            return "Notion Scenarios needs Accessibility permission. Enable it in System Settings, then try again."
        case "screen_capture_permission":
            return "Notion Scenarios needs Screen Recording permission to save a screenshot. Enable it in System Settings, then try again."
        case "document_mismatch":
            return "The Notion document or foreground window changed during the run. Keep the selected document open and try again."
        case "target_window_missing":
            return "Notion did not expose the selected page in time. Make sure the page is open, then try again."
        default:
            return detail
        }
    }
    func loadSavedCaptureComparison() {
        savedCaptureDirectory = nil; savedCaptureImage = nil; savedCaptureAt = ""; screenshotComparison = ""
        guard lastRunOperation == "apply", let expectedVersion = lastRunScenarioVersion,
              let currentImage = image, let root,
              let directories = try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("runs"), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return }
        for directory in directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let resultURL = directory.appendingPathComponent("result.json")
            let requestURL = directory.appendingPathComponent("request.json")
            guard let resultData = try? Data(contentsOf: resultURL),
                  let value = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
                  let requestData = try? Data(contentsOf: requestURL),
                  let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
                  request["operation"] as? String == "capture",
                  value["status"] as? String != "running",
                  value["fixtureId"] as? String == lastRunFixtureId,
                  value["scenarioId"] as? String == lastRunScenarioId,
                  value["scenarioVersion"] as? Int == expectedVersion,
                  value["savedScenario"] as? String == lastRunScenarioId,
                  let screenshot = value["screenshot"] as? [String: Any],
                  let capturedAt = screenshot["capturedAt"] as? String else { continue }
            let captureDirectory = directory.appendingPathComponent("screen.png")
            guard let captureImage = NSImage(contentsOf: captureDirectory) else { continue }
            savedCaptureDirectory = directory
            savedCaptureImage = captureImage
            savedCaptureAt = capturedAt
            screenshotComparison = compareImages(captureImage, currentImage)
            return
        }
    }
    private func compareImages(_ saved: NSImage, _ applied: NSImage) -> String {
        guard let savedCG = saved.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let appliedCG = applied.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return "Pixel comparison unavailable: an image could not be decoded."
        }
        guard savedCG.width == appliedCG.width, savedCG.height == appliedCG.height else {
            return "Image sizes differ: saved \(savedCG.width) × \(savedCG.height), applied \(appliedCG.width) × \(appliedCG.height)."
        }
        guard let savedPixels = rgbaPixels(savedCG), let appliedPixels = rgbaPixels(appliedCG) else {
            return "Pixel comparison unavailable: image data could not be read."
        }
        let pixelCount = savedCG.width * savedCG.height
        var differentPixels = 0
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            if savedPixels[offset] != appliedPixels[offset] || savedPixels[offset + 1] != appliedPixels[offset + 1] ||
                savedPixels[offset + 2] != appliedPixels[offset + 2] || savedPixels[offset + 3] != appliedPixels[offset + 3] {
                differentPixels += 1
            }
        }
        if differentPixels == 0 { return "All pixels identical (\(savedCG.width) × \(savedCG.height))." }
        let matchPercent = 100 * (1 - Double(differentPixels) / Double(pixelCount))
        return String(format: "%.2f%% pixels identical · %d of %d differ", matchPercent, differentPixels, pixelCount)
    }
    private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }
    func save() {
        guard !busy, !editor.isEmpty else { return }
        saveError = ""
        let originalID = selected
        let editedID = (try? JSONSerialization.jsonObject(with: Data(editor.utf8)) as? [String: Any])?["id"] as? String
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        do { try Data(editor.utf8).write(to: file) } catch { saveError = String(describing: error); return }
        var arguments = ["save", file.path]
        if let originalID, let editedID, originalID != editedID {
            arguments += ["--replace-id", originalID]
        }
        command(arguments) { data in
            try? FileManager.default.removeItem(at: file)
            guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else {
                self.saveError = self.messages.split(separator: "\n").last.map(String.init) ?? "Scenario could not be saved."
                return
            }
            self.scenarios.removeAll { $0.id == s.id || $0.id == originalID }; self.scenarios.append(s)
            self.select(s.id)
            self.reload()
        }
    }

    func hasUnsavedChanges(for scenarioID: String) -> Bool {
        selected == scenarioID && hasUnsavedEditorChanges
    }

    func duplicateScenario(_ scenarioID: String) {
        guard !busy else { return }
        guard !hasUnsavedEditorChanges else {
            messages = "Save or discard the current JSON edits before duplicating a scenario."
            return
        }
        guard var copy = scenarios.first(where: { $0.id == scenarioID }) else { return }
        let identity = duplicateIdentity(for: copy)
        copy.id = identity.id
        copy.name = identity.name
        copy.version = 1
        persistNewScenario(copy)
    }

    private func duplicateIdentity(for source: Scenario) -> (id: String, name: String) {
        let usedIDs = Set(scenarios.map(\.id))
        var ordinal = 1
        while true {
            let idSuffix = ordinal == 1 ? "-copy" : "-copy-\(ordinal)"
            let baseLimit = max(1, 80 - idSuffix.count)
            let baseID = String(source.id.prefix(baseLimit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let candidateID = baseID + idSuffix
            if !usedIDs.contains(candidateID) {
                let nameSuffix = ordinal == 1 ? " (copy)" : " (copy \(ordinal))"
                return (candidateID, source.name + nameSuffix)
            }
            ordinal += 1
        }
    }

    private func persistNewScenario(_ scenario: Scenario) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(scenario).write(to: file)
        } catch {
            messages = "Could not prepare the duplicate scenario: \(error)"
            return
        }
        command(["save", file.path, "--create-only"]) { data in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let saved = try? JSONDecoder().decode(Scenario.self, from: data) else {
                self.messages += "\nCould not save the duplicate scenario. See the command output for details."
                self.reload()
                return
            }
            self.scenarios.removeAll { $0.id == saved.id }
            self.scenarios.append(saved)
            self.select(saved.id)
            self.reload(selecting: saved.id)
        }
    }

    func deleteScenario(_ scenarioID: String) {
        guard !busy else { return }
        guard !hasUnsavedChanges(for: scenarioID) else {
            messages = "Save or discard this scenario's JSON edits before deleting it."
            return
        }
        guard let root,
              let scenario = scenarios.first(where: { $0.id == scenarioID }) else { return }
        let folderURL = root.appendingPathComponent("scenarios", isDirectory: true)
            .appendingPathComponent(scenario.fixtureId, isDirectory: true)
        let fileURL = folderURL.appendingPathComponent("\(scenario.id).json")
        let contents: Data
        do {
            contents = try Data(contentsOf: fileURL)
        } catch {
            messages = "Could not read the saved scenario before deleting it: \(error)"
            reload()
            return
        }

        command(["delete", scenarioID]) { data in
            guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  result["deleted"] as? String == scenarioID else {
                self.messages += "\nScenario deletion did not complete. The list was refreshed."
                self.reload()
                return
            }
            self.startUndoWindow(for: DeletedScenario(
                id: scenario.id,
                name: scenario.name,
                rootURL: root.standardizedFileURL,
                fileURL: fileURL,
                contents: contents,
                wasSelected: self.selected == scenarioID,
                token: UUID()
            ))
            self.scenarios.removeAll { $0.id == scenarioID }
            if self.selected == scenarioID { self.select(nil) }
        }
    }

    private func startUndoWindow(for deletion: DeletedScenario) {
        undoExpirationTask?.cancel()
        pendingDeletion = deletion
        undoDeleteMessage = "Deleted \(deletion.name)"
        undoExpirationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, self?.pendingDeletion?.token == deletion.token else { return }
            self?.pendingDeletion = nil
            self?.undoDeleteMessage = nil
        }
    }

    func undoDelete() {
        guard !busy, let deletion = pendingDeletion else { return }
        guard root?.standardizedFileURL == deletion.rootURL else {
            clearPendingDeletion()
            messages = "The fixture folder changed. This deletion can no longer be undone here."
            return
        }
        do {
            try restoreDeletedScenario(deletion)
            clearPendingDeletion()
            messages = "Restored \(deletion.name)."
            let shouldReselect = deletion.wasSelected && !hasUnsavedEditorChanges
            reload(selecting: shouldReselect ? deletion.id : nil)
        } catch {
            clearPendingDeletion()
            messages = "Could not undo the deletion: \(error)"
            reload()
        }
    }

    private func restoreDeletedScenario(_ deletion: DeletedScenario) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: deletion.fileURL.deletingLastPathComponent().path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard !fileManager.fileExists(atPath: deletion.fileURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let temporaryURL = deletion.fileURL.deletingLastPathComponent()
            .appendingPathComponent(".undo-\(UUID().uuidString).tmp")
        do {
            try deletion.contents.write(to: temporaryURL, options: .atomic)
            try fileManager.moveItem(at: temporaryURL, to: deletion.fileURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func clearPendingDeletion() {
        undoExpirationTask?.cancel()
        undoExpirationTask = nil
        pendingDeletion = nil
        undoDeleteMessage = nil
    }

    func applyScenario(_ scenarioID: String) {
        guard !busy else { return }
        guard !hasUnsavedChanges(for: scenarioID) else {
            messages = "Save or discard this scenario's JSON edits before applying it."
            return
        }
        command(["apply", scenarioID, "--json"], result: showResult)
    }

    func capture() {
        guard !blockActionForUnsavedEditorChanges() else { return }
        guard canUseNewId else { messages = newIdIssue ?? "Enter a scenario ID"; return }
        let requestedID = newId
        command(["capture", fixtureId, "--id", requestedID, "--json"]) { data in
            self.showResult(data)
            let savedID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["savedScenario"] as? String
            if savedID == requestedID {
                self.newId = ""
                self.reload(selecting: requestedID)
            } else {
                self.reload()
            }
        }
    }
    func showResult(_ data: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            messages += "\nInvalid result JSON"
            summary = "No result JSON was returned. See Progress & item results for the error."
            runErrorSummary = "No readable result was returned. See Progress & item results for details."
            runStatus = "failed"; lastRunStatus = "failed"
            return
        }
        runStatus = value["status"] as? String ?? "failed"
        lastRunStatus = runStatus
        runErrorSummary = userFacingError(value) ?? ""
        lastRunId = value["runId"] as? String ?? lastRunId
        lastRunFixtureId = value["fixtureId"] as? String ?? lastRunFixtureId
        lastRunScenarioId = value["scenarioId"] as? String ?? lastRunScenarioId
        lastRunScenarioVersion = value["scenarioVersion"] as? Int ?? lastRunScenarioVersion
        lastRunStartedAt = value["startedAt"] as? String ?? lastRunStartedAt
        savedScenarioId = value["savedScenario"] as? String
        screenshotCapturedAt = (value["screenshot"] as? [String: Any])?["capturedAt"] as? String ?? ""
        if let steps = value["steps"], let encoded = try? JSONSerialization.data(withJSONObject: steps),
           let decoded = try? JSONDecoder().decode([StepResult].self, from: encoded) { stepResults = decoded }
        summary = String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? data, encoding: .utf8) ?? ""
        runDirectory = nil; image = nil
        if let path = value["runDirectory"] as? String {
            runDirectory = URL(fileURLWithPath: path)
            image = NSImage(contentsOf: runDirectory!.appendingPathComponent("screen.png"))
        }
        loadSavedCaptureComparison()
    }
    func command(_ arguments: [String], resetProgress: Bool = true, result: @escaping @MainActor (Data) -> Void) {
        guard !busy, let root else { return }
        busy = true
        if resetProgress {
            stepResults = []; messages = "Running: scenario " + arguments.joined(separator: " ") + "\n"
            let operation = arguments.first ?? ""
            runStatus = ["apply", "capture"].contains(operation) ? "running" : ""
            if ["apply", "capture"].contains(operation) {
                lastRunOperation = operation
                let scenarioID = arguments.count > 1 ? arguments[1] : (selected ?? "")
                lastRunFixtureId = operation == "apply"
                    ? (scenarios.first(where: { $0.id == scenarioID })?.fixtureId ?? fixtureId)
                    : fixtureId
                lastRunScenarioId = operation == "capture" ? newId : scenarioID
                lastRunScenarioVersion = nil
                lastRunId = ""; lastRunStartedAt = ""; lastRunStatus = "running"
                savedScenarioId = nil; screenshotCapturedAt = ""
                savedCaptureDirectory = nil; savedCaptureImage = nil; savedCaptureAt = ""; screenshotComparison = ""
                summary = ""; runDirectory = nil; image = nil
                runErrorSummary = ""
            }
        }
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let packagedCLI = Bundle.main.object(forInfoDictionaryKey: "NotionCLIPath") as? String
        Task {
            let output = await Task.detached { () -> Data in
                let process = Process(), stdout = Pipe(), stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", root.appendingPathComponent("fixture").path, "scenario"] + arguments
                var env = ProcessInfo.processInfo.environment
                env["NOTION_SCENARIO_EXECUTABLE"] = executable
                env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
                // Finder does not inherit shell/nvm startup files. Use the CLI
                // installation selected when this developer-local app was built.
                // Include its sibling node executable for npm's /usr/bin/env node.
                if let packagedCLI, FileManager.default.isExecutableFile(atPath: packagedCLI) {
                    let bin = URL(fileURLWithPath: packagedCLI).deletingLastPathComponent().path
                    env["PATH"] = bin + ":" + (env["PATH"] ?? "")
                }
                process.environment = env; process.standardOutput = stdout; process.standardError = stderr
                do {
                    try process.run()
                    // Drain stdout concurrently with progress stderr (large JSON must not deadlock).
                    async let output = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
                    while true {
                        let data = stderr.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        let text = String(decoding: data, as: UTF8.self)
                        await MainActor.run {
                            self.messages += text
                            self.stepResults = self.messages.split(separator: "\n").compactMap { try? JSONDecoder().decode(StepResult.self, from: Data($0.utf8)) }
                        }
                    }
                    process.waitUntilExit()
                    return await output
                } catch {
                    await MainActor.run { self.messages += String(describing: error) }; return Data()
                }
            }.value
            busy = false; result(output)
        }
    }
}
private func scenarioSearchText(_ value: String, query: String) -> AttributedString {
    var result = AttributedString(value)
    guard !query.isEmpty else { return result }
    var start = value.startIndex
    while start < value.endIndex,
          let range = value.range(of: query, options: [.caseInsensitive], range: start..<value.endIndex) {
        if let lower = AttributedString.Index(range.lowerBound, within: result),
           let upper = AttributedString.Index(range.upperBound, within: result) {
            result[lower..<upper].backgroundColor = .yellow.opacity(0.55)
        }
        start = range.upperBound
    }
    return result
}

private struct ScenarioTreeRow: View {
    @ObservedObject var model: ScenarioModel
    let scenario: Scenario
    let searchQuery: String

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(scenarioSearchText(scenario.name, query: searchQuery)).lineLimit(2)
                (Text(scenarioSearchText(scenario.id, query: searchQuery)) + Text(" · v\(scenario.version)\(model.hasUnsavedChanges(for: scenario.id) ? " · Modified" : "")"))
                    .font(.caption)
                    .foregroundStyle(model.hasUnsavedChanges(for: scenario.id) ? .orange : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                Button { model.duplicateScenario(scenario.id) } label: {
                    Image(systemName: "doc.on.doc").scenarioIconButtonHighlight()
                }
                .buttonStyle(.borderless)
                .help(model.hasUnsavedEditorChanges ? "Save or discard JSON edits before duplicating." : "Duplicate saved scenario")
                .accessibilityLabel("Duplicate \(scenario.name)")
                .disabled(model.busy || model.hasUnsavedEditorChanges)

                Button { model.applyScenario(scenario.id) } label: {
                    Image(systemName: "play.fill").scenarioIconButtonHighlight()
                }
                .buttonStyle(.borderless)
                .help(model.hasUnsavedChanges(for: scenario.id) ? "Save or discard JSON edits before applying." : "Apply saved scenario")
                .accessibilityLabel("Apply \(scenario.name)")
                .disabled(model.busy || model.hasUnsavedChanges(for: scenario.id))

                Button(role: .destructive) { model.deleteScenario(scenario.id) } label: {
                    Image(systemName: "trash").scenarioIconButtonHighlight()
                }
                .buttonStyle(.borderless)
                .help(model.hasUnsavedChanges(for: scenario.id) ? "Save or discard JSON edits before deleting." : "Delete scenario")
                .accessibilityLabel("Delete \(scenario.name)")
                .disabled(model.busy || model.hasUnsavedChanges(for: scenario.id))
            }
            .controlSize(.small)
        }
        .contentShape(Rectangle())
        .tag(scenario.id)
    }
}

private struct ScenarioTreeSection: View {
    @ObservedObject var model: ScenarioModel
    let fixture: FixtureItem
    let searchQuery: String
    @State private var isExpanded = true

    private var scenarios: [Scenario] {
        model.scenarios.filter { $0.fixtureId == fixture.id && (searchQuery.isEmpty || $0.name.range(of: searchQuery, options: .caseInsensitive) != nil || $0.id.range(of: searchQuery, options: .caseInsensitive) != nil) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    private var fixtureLabel: String {
        guard let title = fixture.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return fixture.id }
        guard title != fixture.id else { return fixture.id }
        return "\(title) · \(fixture.id)"
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { searchQuery.isEmpty ? isExpanded : true }, set: { if searchQuery.isEmpty { isExpanded = $0 } })) {
            if scenarios.isEmpty {
                Text("No scenarios yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 3)
            } else {
                ForEach(scenarios, id: \.id) { scenario in
                    ScenarioTreeRow(model: model, scenario: scenario, searchQuery: searchQuery)
                }
            }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fixtureLabel)
                        .lineLimit(1)
                    Text("\(scenarios.count) scenario\(scenarios.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
    }
}

struct ScenarioView: View {
    @ObservedObject var model: ScenarioModel
    let comparisonWindowController: ScreenshotComparisonWindowController
    @State private var searchQuery = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var newIDFocused: Bool
    @FocusState private var chooseFolderFocused: Bool
    @State private var newIDSelection: TextSelection?
    @State private var capturePrompt = ""
    @State private var fixturePrompt = ""
    @State private var isUnsavedWarningHighlighted = false
    @State private var unsavedWarningHighlightTask: Task<Void, Never>?

    private func showComparisonWindow(saved: NSImage, applied: NSImage) {
        comparisonWindowController.show(saved: saved, applied: applied, model: model)
    }

    private var captureButtonDisabled: Bool {
        model.busy || model.newIdIssue != nil ||
            (model.newId.isEmpty && !capturePrompt.isEmpty) ||
            (model.root == nil && !fixturePrompt.isEmpty)
    }

    private func attemptCapture() {
        guard !model.blockActionForUnsavedEditorChanges() else { return }
        if model.newId.isEmpty {
            capturePrompt = "새 시나리오 ID를 입력해 주세요."
            newIDFocused = true
            return
        }
        if let issue = model.newIdIssue {
            capturePrompt = issue
            newIDFocused = true
            if issue.hasPrefix("이미 사용 중인 ID") {
                newIDSelection = TextSelection(range: model.newId.startIndex..<model.newId.endIndex)
            }
            return
        }
        if model.root == nil {
            fixturePrompt = "Choose a fixture folder before capturing a scenario."
            chooseFolderFocused = true
            return
        }
        fixturePrompt = ""
        capturePrompt = ""
        model.capture()
    }

    private func highlightBlockedUnsavedEdit() {
        unsavedWarningHighlightTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            isUnsavedWarningHighlighted = true
        }
        unsavedWarningHighlightTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                isUnsavedWarningHighlighted = false
            }
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Button("Choose fixture folder…") { model.chooseRoot() }
                    .focused($chooseFolderFocused)
                    .scenarioHoverHighlight()
                Text(model.root?.path ?? "Select notion-fixtures folder").font(.caption).textSelection(.enabled)
                if !fixturePrompt.isEmpty {
                    Text(fixturePrompt).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("Scenarios").font(.headline)
                    TextField("Search title or ID", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .padding(.leading, 6)
                        .padding(.trailing, 24)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.3)))
                        .overlay(alignment: .trailing) {
                            if searchFocused && !searchQuery.isEmpty {
                                Button {
                                    searchQuery = ""
                                    searchFocused = true
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 5)
                                .accessibilityLabel("Clear scenario search")
                            }
                        }
                        .onExitCommand { if searchFocused { searchQuery = "" } }
                        .accessibilityLabel("Search scenarios by title or ID")
                    Button { model.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                            .scenarioIconButtonHighlight()
                    }
                    .buttonStyle(.borderless)
                    .help("Reload fixture and scenario lists from the selected folder.")
                    .accessibilityLabel("Reload fixture and scenario lists")
                }
                List(selection: Binding(get: { model.selected }, set: { model.requestScenarioSelection($0) })) {
                    if !searchQuery.isEmpty && !model.scenarios.contains(where: { $0.name.range(of: searchQuery, options: .caseInsensitive) != nil || $0.id.range(of: searchQuery, options: .caseInsensitive) != nil }) {
                        Text("No matching scenarios").foregroundStyle(.secondary)
                    }
                    ForEach(model.fixtures.sorted { $0.id < $1.id }) { fixture in
                        ScenarioTreeSection(model: model, fixture: fixture, searchQuery: searchQuery)
                            .frame(height: !searchQuery.isEmpty && !model.scenarios.contains(where: { $0.fixtureId == fixture.id && ($0.name.range(of: searchQuery, options: .caseInsensitive) != nil || $0.id.range(of: searchQuery, options: .caseInsensitive) != nil) }) ? 0 : nil)
                            .clipped()
                            .listRowInsets(!searchQuery.isEmpty && !model.scenarios.contains(where: { $0.fixtureId == fixture.id && ($0.name.range(of: searchQuery, options: .caseInsensitive) != nil || $0.id.range(of: searchQuery, options: .caseInsensitive) != nil) }) ? EdgeInsets() : nil)
                            .listRowSeparator(searchQuery.isEmpty ? .automatic : .hidden)
                    }
                }
                if let undoDeleteMessage = model.undoDeleteMessage {
                    HStack(spacing: 8) {
                        Text(undoDeleteMessage).lineLimit(1)
                        Spacer(minLength: 4)
                        Button("Undo") { model.undoDelete() }
                            .buttonStyle(.link)
                            .scenarioHoverHighlight()
                            .accessibilityLabel("Undo scenario deletion")
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                }
                TextField("New scenario ID", text: $model.newId, selection: $newIDSelection)
                    .focused($newIDFocused)
                    .onChange(of: model.newId) { _, _ in capturePrompt = "" }
                    .onChange(of: model.root) { _, newRoot in
                        if newRoot != nil {
                            capturePrompt = ""
                            fixturePrompt = ""
                        }
                    }
                    .onChange(of: model.selected) { _, _ in capturePrompt = "" }
                if !capturePrompt.isEmpty || model.newIdIssue != nil {
                    let issue = capturePrompt.isEmpty ? model.newIdIssue! : capturePrompt
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
                Button {
                    attemptCapture()
                } label: {
                    Label("Capture as new", systemImage: "viewfinder")
                }
                .scenarioHoverHighlight()
                .disabled(captureButtonDisabled)
                .help("Enter a new scenario ID, then capture the current Notion screen.")
                .accessibilityLabel("Capture current Notion screen as a new scenario")
            }
            .padding()
            .frame(minWidth: 340, idealWidth: 360)
            .disabled(model.busy)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Scenario definition (JSON)").font(.headline)
                    if model.hasUnsavedEditorChanges {
                        Text("Modified")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
                Text("Only observed values are captured. Zoom may remain unsupported. Save edits before applying.").font(.caption).foregroundStyle(.secondary)
                if model.hasUnsavedEditorChanges {
                    HStack(spacing: 10) {
                        Label(model.unsavedEditorNotice, systemImage: "pencil.line")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Save") { model.save() }
                            .scenarioHoverHighlight()
                            .disabled(model.editor.isEmpty || model.busy)
                        Button("Discard changes") { model.discardEditorChanges() }
                            .scenarioHoverHighlight()
                            .disabled(model.busy)
                    }
                    .padding(9)
                    .background(
                        Color.orange.opacity(isUnsavedWarningHighlighted ? 0.32 : 0.12),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .animation(.easeInOut(duration: 0.15), value: isUnsavedWarningHighlighted)
                }
                if !model.saveError.isEmpty {
                    Label(model.saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if model.messages.contains("accessibility_permission") || model.messages.contains("screen_capture_permission") {
                    HStack {
                        Button("Accessibility settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                            .scenarioHoverHighlight()
                        Button("Screen Recording settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                            .scenarioHoverHighlight()
                    }
                }
                ScenarioJSONEditor(text: $model.editor, isEditable: !model.busy)
                    .frame(minHeight: 160)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                isUnsavedWarningHighlighted ? Color.orange : Color.clear,
                                lineWidth: isUnsavedWarningHighlighted ? 2 : 0
                            )
                            .allowsHitTesting(false)
                    }
                    .animation(.easeInOut(duration: 0.15), value: isUnsavedWarningHighlighted)
                if !model.lastRunOperation.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Latest run").font(.headline)
                            Text(model.lastRunOperationLabel).foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 6) {
                                if model.lastRunStatus == "running" {
                                    ProgressView().controlSize(.small)
                                }
                                Text(model.lastRunStatus)
                                    .foregroundStyle(model.lastRunStatus == "verified" ? Color.green : model.lastRunStatus == "failed" ? Color.red : Color.orange)
                            }
                            if let directory = model.runDirectory {
                                Button("Open run folder") { NSWorkspace.shared.open(directory) }
                                    .scenarioHoverHighlight()
                            }
                        }
                        Text("Document: \(model.lastRunFixtureId) · Scenario: \(model.lastRunScenarioId)\(model.lastRunScenarioVersion.map { " · v\($0)" } ?? "")")
                            .font(.caption).textSelection(.enabled)
                        if !model.lastRunStartedAt.isEmpty || !model.lastRunId.isEmpty {
                            Text([model.lastRunTimeLabel.isEmpty ? nil : "Started: \(model.lastRunTimeLabel)",
                                  model.lastRunId.isEmpty ? nil : "Run ID: \(model.lastRunId)"]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let savedScenarioId = model.savedScenarioId {
                            Text("Saved scenario: \(savedScenarioId)")
                                .font(.caption).textSelection(.enabled)
                        }
                        if !model.runErrorSummary.isEmpty {
                            Label(model.runErrorSummary, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(model.lastRunStatus == "partial" ? .orange : .red)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                TabView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(model.stepResults.enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .top) {
                                    Text(step.item).frame(width: 95, alignment: .leading)
                                    Text(step.status).foregroundStyle(step.status == "verified" ? .green : step.status == "unsupported" ? .orange : .red).frame(width: 90, alignment: .leading)
                                    Text(step.detail).textSelection(.enabled)
                                    Spacer()
                                    Text("\(step.durationMs) ms").foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                            Text(model.messages).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.tabItem { Text("Progress & item results") }
                    ScrollView { Text(model.summary).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.tabItem { Text("Requested / observed JSON") }
                    VStack(alignment: .leading, spacing: 8) {
                        if model.lastRunOperation == "apply", let saved = model.savedCaptureImage, let applied = model.image {
                            Text(model.screenshotComparison).font(.caption).bold()
                            HStack(alignment: .top, spacing: 10) {
                                comparisonThumbnail(saved, label: "Saved capture · v\(model.lastRunScenarioVersion ?? 0)", time: model.savedCaptureTimeLabel) {
                                    showComparisonWindow(saved: saved, applied: applied)
                                }
                                Divider()
                                comparisonThumbnail(applied, label: "Latest apply · v\(model.lastRunScenarioVersion ?? 0)", time: model.screenshotTimeLabel) {
                                    showComparisonWindow(saved: saved, applied: applied)
                                }
                            }
                        } else if let image = model.image {
                            if model.lastRunOperation == "apply" {
                                Text("No saved capture screenshot is available for this scenario version.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Screenshot from this run\(model.screenshotTimeLabel.isEmpty ? "" : " · \(model.screenshotTimeLabel)")")
                                .font(.caption).foregroundStyle(.secondary)
                            Image(nsImage: image).resizable().scaledToFit()
                        } else if model.lastRunOperation.isEmpty {
                            Text("Run a scenario to view its screenshot.").font(.caption).foregroundStyle(.secondary)
                        } else if model.lastRunStatus == "running" {
                            Text("Screenshot will appear here if capture succeeds.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No screenshot is available for the latest run. See Progress & item results.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.tabItem { Text("Screenshot") }
                }.frame(minHeight: 250)
            }.padding().frame(minWidth: 620)
        }
        .onChange(of: model.unsavedEditBlockPulse) { _, _ in highlightBlockedUnsavedEdit() }
        .onDisappear {
            unsavedWarningHighlightTask?.cancel()
            unsavedWarningHighlightTask = nil
            isUnsavedWarningHighlighted = false
        }
    }

    private func comparisonThumbnail(_ image: NSImage, label: String, time: String, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !time.isEmpty { Text("· \(time)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(height: 18, alignment: .leading)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scenarioHoverHighlight()
        .help("Open both screenshots in a large comparison window")
        .accessibilityLabel("Open enlarged screenshot comparison: \(label)")
    }
}

private struct ScenarioJSONEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool

    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: ScenarioJSONEditor
        init(_ owner: ScenarioJSONEditor) { self.owner = owner }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            owner.text = view.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        textView.isEditable = isEditable
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.owner = self
        if textView.string != text { textView.string = text }
        textView.isEditable = isEditable
    }
}

private struct ScreenshotComparisonWindowView: View {
    let savedImage: NSImage
    let appliedImage: NSImage
    let savedLabel: String
    let appliedLabel: String
    let comparison: String
    let savedCaptureDirectory: URL?
    let latestApplyDirectory: URL?
    @State private var magnification: CGFloat = 0
    @State private var userHasZoomed = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 5) {
                HStack(alignment: .center) {
                    Text(comparison).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 20)
                    Button { zoomOut() } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .scenarioIconButtonHighlight()
                    }
                        .buttonStyle(.plain)
                        .help("Zoom out (⌘−)")
                        .accessibilityLabel("Zoom out")
                    Button("\(Int((magnification * 100).rounded()))%") { resetZoom() }
                        .scenarioHoverHighlight()
                        .help("Show at 100% (⌘0)")
                        .accessibilityLabel("Reset zoom to 100 percent")
                        .frame(minWidth: 54)
                    Button { zoomIn() } label: {
                        Image(systemName: "plus.magnifyingglass")
                            .scenarioIconButtonHighlight()
                    }
                        .buttonStyle(.plain)
                        .help("Zoom in (⌘+)")
                        .accessibilityLabel("Zoom in")
                }
                HStack(spacing: 0) {
                    screenshotHeader(savedLabel, directory: savedCaptureDirectory, accessibilityLabel: "Open saved capture folder")
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor))
                        .frame(width: 1)
                    screenshotHeader(appliedLabel, directory: latestApplyDirectory, accessibilityLabel: "Open latest apply folder")
                }
                .frame(height: 22)
                ScreenshotComparisonCanvas(savedImage: savedImage, appliedImage: appliedImage, magnification: $magnification)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Drag or scroll to move both screenshots together · ⌘+ / ⌘− to zoom · ⌘0 for 100%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .onAppear {
                guard !userHasZoomed else { return }
                magnification = fittedMagnification(in: geometry.size)
            }
            .onChange(of: geometry.size) { _, size in
                if !userHasZoomed { magnification = fittedMagnification(in: size) }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    private func screenshotHeader(_ title: String, directory: URL?, accessibilityLabel: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let directory {
                Button { NSWorkspace.shared.open(directory) } label: {
                    Image(systemName: "folder")
                        .scenarioIconButtonHighlight()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(accessibilityLabel)
                .accessibilityLabel(accessibilityLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 18, alignment: .leading)
    }

    private func fittedMagnification(in size: CGSize) -> CGFloat {
        let maxWidth = max(savedImage.size.width, appliedImage.size.width)
        let maxHeight = max(savedImage.size.height, appliedImage.size.height)
        guard maxWidth > 0, maxHeight > 0 else { return 1 }
        let panelWidth = max(100, (size.width - 64) / 2)
        let canvasHeight = max(100, size.height - 130)
        return min(1, (panelWidth - 20) / maxWidth, (canvasHeight - 20) / maxHeight)
    }

    private func zoomIn() {
        userHasZoomed = true
        magnification = min(8, max(0.05, magnification) * 1.25)
    }

    private func zoomOut() {
        userHasZoomed = true
        magnification = max(0.05, max(0.05, magnification) / 1.25)
    }

    private func resetZoom() {
        userHasZoomed = true
        magnification = 1
    }
}

private struct ScreenshotComparisonCanvas: NSViewRepresentable {
    let savedImage: NSImage
    let appliedImage: NSImage
    @Binding var magnification: CGFloat

    func makeNSView(context: Context) -> ScreenshotComparisonCanvasView {
        let view = ScreenshotComparisonCanvasView(savedImage: savedImage, appliedImage: appliedImage)
        let zoomBinding = $magnification
        view.onMagnificationChanged = { zoomBinding.wrappedValue = $0 }
        view.magnification = magnification
        return view
    }

    func updateNSView(_ view: ScreenshotComparisonCanvasView, context: Context) {
        view.savedImage = savedImage
        view.appliedImage = appliedImage
        view.magnification = magnification
        let zoomBinding = $magnification
        view.onMagnificationChanged = { zoomBinding.wrappedValue = $0 }
        view.needsDisplay = true
    }
}

private final class ScreenshotComparisonCanvasView: NSView {
    var savedImage: NSImage { didSet { needsDisplay = true } }
    var appliedImage: NSImage { didSet { needsDisplay = true } }
    var magnification: CGFloat = 0 { didSet { needsDisplay = true } }
    var onMagnificationChanged: ((CGFloat) -> Void)?

    private var panOffset = CGPoint.zero
    private var dragStart = CGPoint.zero
    private var panAtDragStart = CGPoint.zero

    init(savedImage: NSImage, appliedImage: NSImage) {
        self.savedImage = savedImage
        self.appliedImage = appliedImage
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        dirtyRect.fill()

        let dividerWidth: CGFloat = 1
        let panelWidth = (bounds.width - dividerWidth) / 2
        let leftPanel = CGRect(x: bounds.minX, y: bounds.minY, width: panelWidth, height: bounds.height)
        let rightPanel = CGRect(x: leftPanel.maxX + dividerWidth, y: bounds.minY, width: panelWidth, height: bounds.height)
        NSColor.separatorColor.setFill()
        CGRect(x: leftPanel.maxX, y: bounds.minY, width: dividerWidth, height: bounds.height).fill()

        let commonWidth = max(savedImage.size.width, appliedImage.size.width)
        let commonHeight = max(savedImage.size.height, appliedImage.size.height)
        guard commonWidth > 0, commonHeight > 0 else { return }
        let fit = min(1, (panelWidth - 32) / commonWidth, (bounds.height - 32) / commonHeight)
        let scale = magnification > 0 ? magnification : fit

        draw(savedImage, in: leftPanel, commonWidth: commonWidth, commonHeight: commonHeight, scale: scale)
        draw(appliedImage, in: rightPanel, commonWidth: commonWidth, commonHeight: commonHeight, scale: scale)
    }

    private func draw(_ image: NSImage, in panel: CGRect, commonWidth: CGFloat, commonHeight: CGFloat, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: panel).addClip()
        let commonOrigin = CGPoint(
            x: panel.midX - commonWidth * scale / 2 + panOffset.x,
            y: panel.minY + panOffset.y
        )
        let imageRect = CGRect(
            x: commonOrigin.x,
            y: commonOrigin.y,
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        panAtDragStart = panOffset
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        panOffset = CGPoint(x: panAtDragStart.x + point.x - dragStart.x, y: panAtDragStart.y + point.y - dragStart.y)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        panOffset = CGPoint(x: panOffset.x + event.scrollingDeltaX, y: panOffset.y + event.scrollingDeltaY)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { super.keyDown(with: event); return }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "+", "=": onMagnificationChanged?(min(8, max(0.05, magnification) * 1.25))
        case "-": onMagnificationChanged?(max(0.05, max(0.05, magnification) / 1.25))
        case "0": onMagnificationChanged?(1)
        default: super.keyDown(with: event)
        }
    }
}
