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
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1060, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Notion Screen Scenarios"
        window.contentView = NSHostingView(rootView: ScenarioView(model: model))
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
struct FixtureItem: Decodable, Identifiable { var id: String; var version: String }
struct Listing: Decodable { var fixtures: [FixtureItem]; var scenarios: [Scenario] }
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
    @Published var summary = ""
    @Published var runStatus = ""
    @Published var image: NSImage?
    @Published var runDirectory: URL?
    var current: Scenario? { scenarios.first { $0.id == selected } }
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
        if root != nil { reload() }
    }
    func chooseRoot() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose the notion-fixtures folder containing the fixture CLI"
        if panel.runModal() == .OK, let url = panel.url {
            root = url; UserDefaults.standard.set(url.path, forKey: "fixtureRoot"); reload()
        }
    }
    func select(_ id: String?) {
        selected = id
        guard let s = current else { editor = ""; savedEditor = ""; return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        editor = String(data: (try? encoder.encode(s)) ?? Data(), encoding: .utf8) ?? ""
        savedEditor = editor
    }
    func reload() {
        command(["list", "--json"], resetProgress: false) { data in
            do {
                let listing = try JSONDecoder().decode(Listing.self, from: data)
                self.fixtures = listing.fixtures; self.scenarios = listing.scenarios
                if let selected = self.selected, self.editor == self.savedEditor { self.select(selected) }
                if !self.fixtures.contains(where: { $0.id == self.fixtureId }) { self.fixtureId = self.fixtures.first?.id ?? "" }
            } catch { self.messages += "\n\(error)" }
        }
    }
    func create() {
        guard canUseNewId else { messages = newIdIssue ?? "Enter a scenario ID"; return }
        guard let fixture = fixtures.first(where: { $0.id == fixtureId }) else { return }
        let state = #"{"coordinateSystem":"screen-top-left-points","window":{"x":0,"y":60,"width":1024,"height":700},"scroll":{"mode":"top"},"focus":{"mode":"clear"},"required":["target","window","scroll","focus","screenshot"]}"#
        guard let requested = try? JSONDecoder().decode(RequestedState.self, from: Data(state.utf8)) else { return }
        let s = Scenario(id: newId, name: newId, fixtureId: fixture.id, fixtureVersion: fixture.version, state: requested)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        editor = String(data: (try? encoder.encode(s)) ?? Data(), encoding: .utf8) ?? ""; selected = nil
    }
    func duplicate() {
        guard canUseNewId else { messages = newIdIssue ?? "Enter a scenario ID"; return }
        guard var value = try? JSONSerialization.jsonObject(with: Data(editor.utf8)) as? [String: Any] else { return }
        value["id"] = newId; value["name"] = newId; value["version"] = 1
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            editor = String(decoding: data, as: UTF8.self); selected = nil
        }
    }
    func save() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        do { try Data(editor.utf8).write(to: file) } catch { messages = String(describing: error); return }
        command(["save", file.path]) { data in
            try? FileManager.default.removeItem(at: file)
            guard let s = try? JSONDecoder().decode(Scenario.self, from: data) else { return }
            self.scenarios.removeAll { $0.id == s.id }; self.scenarios.append(s)
            self.select(s.id)
            self.reload()
        }
    }
    func remove() {
        guard let selected else { return }
        command(["delete", selected]) { _ in self.select(nil); self.reload() }
    }
    func apply() { if let selected { command(["apply", selected, "--json"], result: showResult) } }
    func capture() {
        guard canUseNewId else { messages = newIdIssue ?? "Enter a scenario ID"; return }
        command(["capture", fixtureId, "--id", newId, "--json"]) { data in self.showResult(data); self.reload() }
    }
    func showResult(_ data: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { messages += "\nInvalid result JSON"; runStatus = "failed"; return }
        runStatus = value["status"] as? String ?? "failed"
        if let steps = value["steps"], let encoded = try? JSONSerialization.data(withJSONObject: steps),
           let decoded = try? JSONDecoder().decode([StepResult].self, from: encoded) { stepResults = decoded }
        summary = String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? data, encoding: .utf8) ?? ""
        if let path = value["runDirectory"] as? String {
            runDirectory = URL(fileURLWithPath: path)
            image = NSImage(contentsOf: runDirectory!.appendingPathComponent("screen.png"))
        }
    }
    func command(_ arguments: [String], resetProgress: Bool = true, result: @escaping @MainActor (Data) -> Void) {
        guard !busy, let root else { return }
        busy = true
        if resetProgress {
            stepResults = []; messages = "Running: scenario " + arguments.joined(separator: " ") + "\n"
            runStatus = ["apply", "capture"].contains(arguments.first ?? "") ? "running" : ""
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
struct ScenarioView: View {
    @ObservedObject var model: ScenarioModel
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Button("Choose fixture folder…") { model.chooseRoot() }
                Text(model.root?.path ?? "Select notion-fixtures folder").font(.caption).textSelection(.enabled)
                Picker("Document", selection: $model.fixtureId) {
                    ForEach(model.fixtures) { Text($0.id).tag($0.id) }
                }.onChange(of: model.fixtureId) { _, _ in model.select(nil) }
                List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
                    ForEach(model.scenarios.filter { $0.fixtureId == model.fixtureId }, id: \.id) { s in
                        VStack(alignment: .leading) { Text(s.name); Text("\(s.id) · v\(s.version)").font(.caption).foregroundStyle(.secondary) }.tag(s.id)
                    }
                }
                TextField("New scenario ID", text: $model.newId)
                if let issue = model.newIdIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
                HStack {
                    Button("Create") { model.create() }.disabled(!model.canUseNewId)
                    Button("Duplicate") { model.duplicate() }.disabled(!model.canUseNewId || model.editor.isEmpty)
                }
                Button("Save current Notion screen") { model.capture() }.disabled(!model.canUseNewId)
                Button("Refresh") { model.reload() }
            }.padding().frame(minWidth: 260, idealWidth: 300).disabled(model.busy)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Scenario definition (JSON)").font(.headline)
                    Spacer()
                    if !model.runStatus.isEmpty { Text(model.runStatus).font(.headline).foregroundStyle(model.runStatus == "verified" ? .green : model.runStatus == "failed" ? .red : .orange) }
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("Save") { model.save() }.disabled(model.editor.isEmpty || model.busy)
                    Button("Delete", role: .destructive) { model.remove() }.disabled(model.selected == nil || model.busy)
                    Button("Apply saved scenario") { model.apply() }.disabled(model.selected == nil || model.busy || model.editor != model.savedEditor)
                }
                Text("Only observed values are captured. Zoom may remain unsupported. Save edits before applying.").font(.caption).foregroundStyle(.secondary)
                if model.messages.contains("accessibility_permission") || model.messages.contains("screen_capture_permission") {
                    HStack {
                        Button("Accessibility settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
                        Button("Screen Recording settings…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
                    }
                }
                TextEditor(text: $model.editor).font(.system(.body, design: .monospaced)).frame(minHeight: 160).disabled(model.busy)
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
                    VStack {
                        if let image = model.image { Image(nsImage: image).resizable().scaledToFit() }
                        if let directory = model.runDirectory { Button("Open run folder") { NSWorkspace.shared.open(directory) } }
                    }.tabItem { Text("Screenshot") }
                }.frame(minHeight: 250)
            }.padding().frame(minWidth: 620)
        }
    }
}
