import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CryptoKit

@MainActor
public final class ScenarioRunner {
    private var ax: Accessibility!
    private var window: AXUIElement!
    private var web: AXUIElement!
    private var deadline = Date()
    private var stepDeadline = Date()
    private var request: RunRequest!
    private var result: RunResult!
    private var directory: URL!
    private var scopeOverride: AXUIElement?
    private var regionFrame: CGRect?
    private var scrollObservations: [Int: CGRect] = [:]
    private var scrollFullSizes: [Int: CGFloat] = [:]
    private var boundaryElements: [Int: (AXUIElement, CGRect)] = [:]
    private var visualBoundaries: [Int: String] = [:]
    private var boundaryLabels: [Int: String] = [:]
    private var markerRanges: [String: CFTypeRef] = [:]
    private var visualFrames: [Int: CGRect] = [:]
    private var progress: ((StepResult) -> Void)?
    private var timelineTodayApplied = false
    public init() {}
    public static func inspectCurrentWindow() throws -> Data {
        let ax = try Accessibility()
        let target = try ax.focusedTarget()
        var rows: [[String: Any]] = []
        func visit(_ node: AXUIElement, parent: Int, depth: Int) {
            guard rows.count < 6000, depth < 45 else { return }
            let index = rows.count
            var row: [String: Any] = ["index": index, "parent": parent, "classes": ax.classes(node)]
            for key in ["AXRole", "AXRoleDescription", "AXTitle", "AXDescription", "AXValue", "AXURL", "AXHelp", "AXPlaceholderValue", "AXExpanded", "AXSelected", "AXVisibleCharacterRange", "AXSelectedTextRange"] {
                if let value = ax.get(node, key) { row[key] = String(describing: value) }
            }
            if let frame = ax.frame(node) { row["frame"] = [frame.minX, frame.minY, frame.width, frame.height] }
            var names: CFArray?
            if AXUIElementCopyAttributeNames(node, &names) == .success { row["attributes"] = names as? [String] }
            var actions: CFArray?
            if AXUIElementCopyActionNames(node, &actions) == .success { row["actions"] = actions as? [String] }
            var parameters: CFArray?
            if AXUIElementCopyParameterizedAttributeNames(node, &parameters) == .success { row["parameterizedAttributes"] = parameters as? [String] }
            if ax.text(node,"AXRole") == "AXTextArea", ax.text(node,"AXValue").utf16.count > 1000 {
                var range = CFRange(location:0,length:20)
                var value: CFTypeRef?
                if let parameter = AXValueCreate(.cfRange,&range) {
                    let status = AXUIElementCopyParameterizedAttributeValue(node,"AXBoundsForRange" as CFString,parameter,&value)
                    row["prefixBoundsStatus"] = status.rawValue
                    if let value { row["prefixBoundsValue"] = String(describing:value) }
                }
            }
            rows.append(row)
            for child in ax.children(node) { visit(child, parent: index, depth: depth + 1) }
        }
        visit(target.window, parent: -1, depth: 0)
        return try JSONSerialization.data(withJSONObject: ["pageId": target.pageId, "nodes": rows], options: [.prettyPrinted, .sortedKeys])
    }
    public static func resolveCurrentPageID() throws -> String {
        try Accessibility().focusedTarget().pageId
    }
    private func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    private func checkTime() throws {
        if Task.isCancelled || Date() >= min(deadline, stepDeadline) { throw ScenarioFailure("timeout", "State did not converge within the time limit") }
        if web != nil { try guardTarget() }
    }
    private func pause() async throws { try checkTime(); try await Task.sleep(for: .milliseconds(150)); try checkTime() }
    private func wait(_ condition: () throws -> Bool) async throws {
        var stable = 0
        while stable < 2 {
            try checkTime()
            stable = try condition() ? stable + 1 : 0
            if stable < 2 { try await pause() }
        }
    }
    private func waitForToggleState(_ anchor: Anchor, expanded: Bool, timeout: TimeInterval) async throws -> Bool {
        let priorDeadline = stepDeadline
        stepDeadline = min(priorDeadline, Date().addingTimeInterval(timeout))
        defer { stepDeadline = priorDeadline }
        do {
            try await wait { try self.toggleState(anchor).0 == expanded }
            return true
        } catch let error as ScenarioFailure where error.code == "timeout" {
            return false
        }
    }
    private func guardTarget() throws {
        if !ax.isPage(web, pageId: request.pageId) {
            let candidates = ax.nodes(window).filter { ax.text($0, "AXRole") == "AXWebArea" && ax.isPage($0, pageId: request.pageId) }
            if candidates.count == 1 { web = candidates[0] }
        }
        guard (ax.isPage(web, pageId: request.pageId) || (request.scenario.state.presentation?.mode == "full" && request.previewPageId.map { ax.isPage(web, pageId: $0) } == true)), ax.process.isActive,
              let focused = ax.get(ax.app, "AXFocusedWindow"), CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, window) else {
            result.environment["unexpectedFrontmostApp"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
            result.environment["unexpectedPageId"] = ax.pageID(web) ?? "unavailable"
            throw ScenarioFailure("document_mismatch", "Notion target document or foreground application changed")
        }
    }
    private func viewport() throws -> (AXUIElement, CGRect) {
        guard let e = ax.viewport(contentRoot), let r = ax.frame(e), r.width > 0, r.height > 0 else {
            throw ScenarioFailure("unsupported", "Notion body viewport is not exposed by public AX")
        }
        return (e, r)
    }
    private func step(_ item: String, _ body: () async throws -> Void) async {
        let start = Date()
        var failure: ScenarioFailure?
        var attempts = 0
        let isToggle = item.hasPrefix("toggle.")
        let maxAttempts = isToggle ? 1 : 3
        var attemptDiagnostics: [String] = []
        // Retry convergent steps, but keep captures and toggles single-shot to avoid repeating delayed UI actions.
        for attempt in 0..<maxAttempts {
            attempts = attempt + 1
            let captureTarget = item == "target" && request.operation == "capture"
            stepDeadline = min(deadline, Date().addingTimeInterval(captureTarget ? 5 : (isToggle ? 15 : 10)))
            if item == "presentation" { result.environment["presentation.phase"] = "attempt-\(attempt + 1):starting" }
            do {
                try checkTime()
                if item != "target" { try guardTarget() }
                try await body()
                failure = nil
                if item == "presentation" { attemptDiagnostics.append("attempt \(attempt + 1): verified") }
                break
            }
            catch let error as ScenarioFailure {
                failure = error
                if item == "presentation" {
                    let phase = result.environment["presentation.phase"] ?? "phase unavailable"
                    attemptDiagnostics.append("attempt \(attempt + 1): \(error.code) at \(phase): \(error.description)")
                }
                if error.code != "timeout" || captureTarget || attempt == maxAttempts - 1 || Date() >= deadline { break }
            } catch {
                failure = ScenarioFailure("operation_failed", String(describing: error))
                if item == "presentation" {
                    let phase = result.environment["presentation.phase"] ?? "phase unavailable"
                    attemptDiagnostics.append("attempt \(attempt + 1): operation_failed at \(phase): \(String(describing: error))")
                }
                break
            }
        }
        if item == "presentation", !attemptDiagnostics.isEmpty {
            result.environment["presentation.attempts"] = attemptDiagnostics.joined(separator: " | ")
        }
        var record = StepResult(item: item, status: failure == nil ? "verified" : (failure!.code == "unsupported" ? "unsupported" : "failed"),
                                code: failure?.code,
                                detail: failure.map { error in
                                    let trace = item == "presentation" && !attemptDiagnostics.isEmpty ? " Attempts: \(attemptDiagnostics.joined(separator: "; "))" : ""
                                    return error.description + trace
                                } ?? "Observed requested state",
                                durationMs: Int(Date().timeIntervalSince(start) * 1000))
        record.attempts = attempts
        result.steps.append(record); progress?(record)
        if request.scenario.state.databaseView != nil, ax != nil, web != nil {
            result.environment["databaseViewAfter.\(item)"] = currentDatabaseView() ?? "unavailable"
        }
        try? save()
    }
    private func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
    public func run(_ request: RunRequest, directory: URL, progress: ((StepResult) -> Void)? = nil) async -> RunResult {
        self.request = request; self.directory = directory; scopeOverride = nil; regionFrame = nil; scrollObservations = [:]; scrollFullSizes = [:]; boundaryElements = [:]; visualBoundaries = [:]; boundaryLabels = [:]; markerRanges = [:]; visualFrames = [:]; self.progress = progress; measuredAnchorHeight = nil; web = nil; window = nil
        deadline = Date().addingTimeInterval(min(120, max(1, request.timeoutSeconds ?? 120)))
        result = RunResult(runId: request.runId, fixtureId: request.scenario.fixtureId, fixtureVersion: request.scenario.fixtureVersion,
                           scenarioId: request.scenario.id, scenarioVersion: request.scenario.version, startedAt: now(), status: "running",
                           requested: request.scenario.state, observed: RequestedState(), steps: [], environment: [:])
        result.observed.required = []
        result.environment["macOS"] = ProcessInfo.processInfo.operatingSystemVersionString
        for (i, screen) in NSScreen.screens.enumerated() {
            let frame = screen.frame
            result.environment["display.\(i)"] = "id=\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown") cocoaFrame=\(frame) scale=\(screen.backingScaleFactor)"
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let reason = ReplaySafety.rejection(for: request.scenario, operation: request.operation,
                                               databaseViewTypes: request.databaseViewTypes,
                                               allowPersistentPresentation: request.allowPersistentPresentation == true) {
            result.steps.append(StepResult(item: "replayPolicy", status: "unsupported",
                                           code: "persistent_presentation_unsupported", detail: reason,
                                           durationMs: 0))
            result.status = "partial"
            try? save()
            return result
        }
        await step("target") {
            guard [1, 2].contains(request.scenario.schemaVersion), request.scenario.state.coordinateSystem == "screen-top-left-points",
                  UUID(uuidString: request.pageId) != nil, ["apply", "capture"].contains(request.operation) else {
                throw ScenarioFailure("invalid_request", "Unsupported scenario schema, coordinate system, operation, or page ID")
            }
            self.ax = try Accessibility()
            self.result.environment["postEventAccess"] = String(CGPreflightPostEventAccess())
            if request.operation == "apply" && !CGPreflightPostEventAccess() {
                throw ScenarioFailure("accessibility_permission", "macOS denied synthetic UI input; enable Accessibility for the actual runner application")
            }
            self.result.environment["notion"] = Bundle(url: self.ax.process.bundleURL!)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let selectedTarget: (AXUIElement, AXUIElement)
            if request.operation == "capture" {
                if request.requireFocusedPage == true {
                    let focused = try self.ax.focusedTarget()
                    guard focused.pageId == request.pageId else {
                        throw ScenarioFailure("current_page_changed", "The focused Notion page changed before capture started")
                    }
                    selectedTarget = (focused.window, focused.web)
                } else {
                    let targets = self.ax.targets(pageId: request.pageId)
                    if targets.count > 1 {
                        throw ScenarioFailure("ambiguous_window", "The selected document is open in multiple windows; close duplicate windows")
                    }
                    guard let target = targets.first else {
                        throw ScenarioFailure("selected_document_not_found", "Could not find selected document '\(request.scenario.fixtureId)' in a Notion window. Open that page and try again.")
                    }
                    selectedTarget = target
                }
            } else {
                var targets = self.ax.targets(pageId: request.pageId)
                if targets.isEmpty {
                    let compact = request.pageId.replacingOccurrences(of: "-", with: "")
                    NSWorkspace.shared.open(URL(string: "notion://www.notion.so/\(compact)")!)
                }
                try await self.wait {
                    targets = self.ax.targets(pageId: request.pageId)
                    if targets.count > 1 { throw ScenarioFailure("ambiguous_window", "The page is open in multiple windows; close duplicate windows") }
                    return targets.count == 1
                }
                selectedTarget = (targets[0].0, targets[0].1)
            }
            self.window = selectedTarget.0; let targetWeb = selectedTarget.1
            self.ax.process.activate()
            try self.ax.press(self.window, action: "AXRaise")
            try await self.wait {
                guard self.ax.process.isActive, let focused = self.ax.get(self.ax.app, "AXFocusedWindow") else { return false }
                return CFEqual(focused, self.window)
            }
            self.web = targetWeb
            self.result.environment["pageId"] = request.pageId
            self.result.environment["documentURL"] = self.ax.get(self.web, "AXURL").map { String(describing: $0) } ?? ""
        }
        guard result.steps.last?.status == "verified" else {
            if result.steps.last?.code == "timeout" {
                if request.operation == "capture" {
                    result.steps[result.steps.count - 1].code = "target_window_focus_failed"
                    result.steps[result.steps.count - 1].detail = "The selected document was found, but its Notion window could not be brought forward"
                } else {
                    result.steps[result.steps.count - 1].code = "target_window_missing"
                    result.steps[result.steps.count - 1].detail = "No window exposing the requested Notion document URL was found"
                }
            }
            result.status = "failed"; result.finishedAt = now(); try? save(); return result
        }
        if request.operation == "capture" { await captureState() }
        else { await applyState() }
        if request.scenario.state.captureRegion != nil {
            await step("captureRegion") {
                self.regionFrame = try self.requestedRegion()
                self.result.observed.captureRegion = request.scenario.state.captureRegion
                self.result.observedGeometry["captureRegion"] = Rect(self.regionFrame!)
            }
        }
        await step("screenshot") { try await self.screenshot() }
        // Read back again AFTER all actions, including focus and screenshot. Earlier
        // observations alone must never prove final state after later layout changes.
        if request.operation == "apply" { await verifyFinal() }
        if let frame = ax.frame(window) { result.observed.window = Rect(frame) }
        result.observed.sidebarOpen = sidebar()?.0
        result.status = RunResult.verdict(required: request.scenario.state.required, steps: result.steps)
        result.finishedAt = now(); try? save()
        return result
    }
    private func sidebar() -> (Bool, AXUIElement)? {
        for n in ax.nodes(window) where ax.text(n, "AXRole") == "AXButton" {
            let label = ax.text(n, "AXDescription")
            if label == "Close Sidebar" { return (true, n) }
            if label == "Open Sidebar" { return (false, n) }
        }
        return nil
    }
    private func applyState() async {
        let state = request.scenario.state
        if request.scenario.schemaVersion == 2 {
            let transient = ax.nodes(web).contains { ["AXMenu", "AXComboBox", "AXMenuItem"].contains(ax.text($0, "AXRole")) }
            if transient { ax.key(53); try? await pause() }
        }
        if let frame = state.window {
            await step("window") {
                guard NSScreen.screens.contains(where: { screen in
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    let f = screen.visibleFrame
                    let available = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
                    return available.insetBy(dx: -2, dy: -2).contains(frame.cgRect)
                }) else { throw ScenarioFailure("window_out_of_bounds", "Requested frame does not fit a display's usable area; no silent resizing") }
                for _ in 0..<3 {
                    try self.ax.setFrame(self.window, frame.cgRect)
                    try await self.pause()
                    if self.ax.frame(self.window).map({ frame.near(Rect($0)) }) == true { break }
                }
                try await self.wait { self.ax.frame(self.window).map { frame.near(Rect($0)) } ?? false }
                self.result.observed.window = Rect(self.ax.frame(self.window)!)
            }
        }
        if let zoom = state.zoomPercent {
            await step("zoom") {
                // These public commands are idempotent for Actual Size. There is no
                // public numeric readback in the tested Notion release.
                if zoom == 100 { try self.ax.menu("Actual Size"); self.result.environment["zoomCommandsApplied"] = "Actual Size" }
                else if zoom == 125 { try self.ax.menu("Actual Size"); try self.ax.menu("Zoom In"); self.result.environment["zoomCommandsApplied"] = "Actual Size;Zoom In" }
                throw ScenarioFailure("unsupported", "Requested \(zoom)%; public Notion UI exposes no readable numeric zoom. Commands, if available, are attempts only; actual percentage is unknown.")
            }
        }
        if let open = state.sidebarOpen {
            await step("sidebar") {
                guard let current = self.sidebar() else { throw ScenarioFailure("unsupported", "Readable sidebar button unavailable in this Notion locale") }
                if current.0 != open { try await self.setSidebarPinned(open) }
                try await self.wait { self.sidebar()?.0 == open }
                self.result.observed.sidebarOpen = self.sidebar()?.0
            }
        }
        if request.scenario.schemaVersion == 2 { await prepareScreenState() }
        for (index, toggle) in (state.toggles ?? []).enumerated() {
            await step("toggle.\(index)") {
                try await self.locate(toggle.anchor)
                // Find/ScrollToVisible can leave a formatting popover and selection
                // above the disclosure. Clear transient UI before performing it.
                if self.request.scenario.state.focus?.mode == "clear" {
                    try await self.focus(FocusRequest(mode: "clear"))
                }
                self.result.environment["toggle.\(index).anchorLookup"] = self.result.environment["anchorLookup"]
                let (expanded, button) = try self.toggleState(toggle.anchor)
                if expanded != toggle.expanded {
                    // Prefer AXPress. Some Notion builds return success without changing
                    // AXExpanded, so fall back to a mouse click only if state stays put.
                    do { try self.ax.press(button) }
                    catch let error as ScenarioFailure where error.code != "unsupported" { throw error }
                    if !(try await self.waitForToggleState(toggle.anchor, expanded: toggle.expanded, timeout: 0.75)) {
                        let (current, currentButton) = try self.toggleState(toggle.anchor)
                        if current != toggle.expanded { try self.ax.click(currentButton) }
                    }
                }
                try await self.wait { try self.toggleState(toggle.anchor).0 == toggle.expanded }
                self.result.observed.toggles = (self.result.observed.toggles ?? []) + [toggle]
            }
        }
        if let scroll = state.scroll { await step("scroll") { try await self.settleLayout(); try await self.scroll(scroll) } }
        if request.scenario.schemaVersion == 2 { await applyScopedScrolls() }
        if request.scenario.schemaVersion == 2 { await applyBlockDisplays() }
        if let focus = state.focus { await step("focus") { try await self.focus(focus) } }
        if let overlay = state.overlay {
            if ["menu","popup"].contains(overlay.kind) { await verifyFinal(item:"backgroundState",includeOverlay:false) }
            await step("overlay") { try await self.applyOverlay(overlay) }
        }
        if let side = state.sidebar, side.mode == "floating" {
            await step("sidebar") { try await self.applySidebar(side) }
            // Resizing/revealing the sidebar can focus a sidebar control. Restore
            // the requested nonediting focus without parking the pointer (which
            // would immediately dismiss the requested floating pane).
            if state.focus?.mode == "clear" { try? ax.set(web,"AXFocused",kCFBooleanTrue) }
        }
        await stabilizeVisualScrollBaselines()
    }
    private func stabilizeVisualScrollBaselines() async {
        for (index, scroll) in (request.scenario.state.scrolls ?? []).enumerated()
        where visualFrames[index] != nil {
            await step("scroll.\(index).stableBaseline") {
                // Pixel proofs are also used by ordinary paragraph scrolling
                // (advancePixels). Only code panes need their hover controls
                // exposed; requiring a code block here breaks main/preview scrolls.
                if scroll.scope == "code" {
                    try await self.hoverCodeBlock(container: scroll.container)
                }
                let (viewport, bounds) = try self.scopedViewport(scroll.scope, container: scroll.container, axis: scroll.axis)
                self.parkPointer()
                var previous = "", stable = 0
                while stable < 3 {
                    try await self.pause()
                    let current = try await self.viewportPixels(viewport)
                    stable = current == previous ? stable + 1 : 0
                    previous = current
                }
                self.visualFrames[index] = bounds
                self.visualBoundaries[index] = previous
                try await self.saveDiagnosticScreenshot("scroll-stable-\(index).png")
                self.result.environment["scroll.\(index).stableBaseline"] = "Pointer parked and viewport pixels stable after requested focus and overlay state"
            }
        }
    }
    private func codeBlock(container: Anchor?) throws -> AXUIElement {
        let source = try root("code")
        if let container {
            guard let text = try ax.unique(container, in: source) else {
                throw ScenarioFailure("anchor_missing", "Code content anchor is not loaded")
            }
            var current: AXUIElement? = text
            var enclosing: [(AXUIElement, CGRect)] = []
            for _ in 0..<20 {
                guard let node = current else { break }
                let frame = ax.frame(node)
                if ax.classes(node).contains("notion-code-block"),
                   let frame, frame.width >= 100, frame.height >= 40 { enclosing.append((node, frame)) }
                current = ax.parent(node)
            }
            if let outermost = enclosing.last { return outermost.0 }
            throw ScenarioFailure("unsupported", "The anchored text has no enclosing code block with a visible viewport-sized frame")
        }
        let candidates = ax.nodes(source).filter { node in
            ax.classes(node).contains("notion-code-block") &&
            (ax.frame(node).map { $0.width >= 100 && $0.height >= 40 } ?? false)
        }
        guard candidates.count == 1, let target = candidates.first else {
            throw ScenarioFailure("unsupported", "Cannot uniquely identify a visible code block by its frame")
        }
        return target
    }
    private func hoverCodeBlock(container: Anchor?) async throws {
        let target = try codeBlock(container: container)
        guard let frame = ax.frame(target) else { throw ScenarioFailure("unsupported", "Code block frame is unavailable") }
        ax.move(CGPoint(x: frame.midX, y: frame.midY))
        try await Task.sleep(for: .milliseconds(700))
        try checkTime()
    }
    private func primeCodeHorizontalScroll(container: Anchor?) async throws {
        let target = try codeBlock(container: container)
        guard let frame = ax.frame(target) else { throw ScenarioFailure("unsupported", "Code block frame is unavailable") }
        let before = try await framePixels(frame)
        try ax.wheel(Int(frame.width.rounded()), viewport: target, horizontal: true)
        var moved = false
        for _ in 0..<12 {
            try await pause()
            if try await framePixels(frame) != before { moved = true; break }
        }
        guard moved else { throw ScenarioFailure("unsupported", "Code block horizontal wheel input produced no visible pixel movement") }
        result.environment["codeHorizontalPriming"] = "Wheel sent over code block; visible movement confirmed before resolving its horizontal viewport"
    }
    private func settleLayout() async throws {
        var previous: [Rect] = [], stable = 0
        while stable < 2 {
            try checkTime()
            let (_, viewport) = try self.viewport()
            let rects = [Rect(viewport)] + ax.leaves(contentRoot).prefix(4).compactMap { ax.frame($0).map(Rect.init) }
            stable = rects == previous ? stable + 1 : 0
            previous = rects
            if stable < 2 { try await pause() }
        }
    }
    private func locate(_ anchor: Anchor) async throws {
        // Chromium clamps offscreen text to 1pt edge rectangles. A positive
        // frame alone does not establish a safe click target; bring it into the
        // body viewport first. This is replay geometry, not a glyph-visibility claim.
        func usable(_ element: AXUIElement) throws -> Bool {
            guard let r = ax.frame(element), r.width > 1, r.height > 1 else { return false }
            let visible = r.intersection(try viewport().1)
            return !visible.isNull && visible.width > 1 && visible.height > 1
        }
        func scanViewport() async throws -> Bool {
            guard let pane = ax.viewport(contentRoot), let bounds = ax.frame(pane) else { return false }
            try ax.wheel(100_000, viewport: pane)
            try await pause()
            for _ in 0..<64 {
                if let node = try ax.unique(anchor, in: contentRoot), try usable(node) { return true }
                try ax.wheel(-Int(max(100, bounds.height * 0.7)), viewport: pane)
                try await pause()
            }
            return false
        }
        if let e = try ax.unique(anchor, in: contentRoot), try usable(e) {
            result.environment["anchorLookup"] = "visible-AX"
            return
        }
        if let element = try ax.unique(anchor, in: contentRoot) {
            try? ax.press(element, action: "AXScrollToVisible")
            try await pause()
            if let current = try ax.unique(anchor, in: contentRoot), try usable(current) {
                result.environment["anchorLookup"] = "AXScrollToVisible"
                return
            }
        }
        // Notion's Find command can search the background page even when the
        // peek editor owns AX focus. Discover virtualized preview anchors by
        // scrolling that pane itself, without changing either document.
        if ax.classes(contentRoot).contains("notion-peek-renderer") {
            if try await scanViewport() { return }
            throw ScenarioFailure("anchor_missing", "Preview anchor was not exposed while scanning its own viewport")
        }
        if request.scenario.schemaVersion == 2, let editor = ax.editor(contentRoot) {
            try ax.set(editor, "AXFocused", kCFBooleanTrue)
        }
        result.environment["anchorLookup"] = "Find"
        ax.key(3, flags: .maskCommand) // Find, never the document's editable content.
        var field: AXUIElement?
        try await wait {
            field = self.ax.nodes(self.window).first {
                ["AXTextField", "AXSearchField"].contains(self.ax.text($0, "AXRole")) &&
                self.ax.text($0, "AXPlaceholderValue").lowercased().contains("find")
            }
            return field != nil
        }
        try ax.set(field!, "AXFocused", kCFBooleanTrue)
        try await wait {
            guard let raw = self.ax.get(self.ax.app, "AXFocusedUIElement"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
            return CFEqual(raw as! AXUIElement, field!)
        }
        try ax.set(field!, "AXValue", anchor.text as CFString)
        try await wait { self.ax.text(field!, "AXValue") == anchor.text }
        // AXValue can update Find without submitting the query. Reserve time
        // for Return instead of consuming the whole step deadline waiting for it.
        let findDeadline = stepDeadline
        stepDeadline = min(findDeadline, Date().addingTimeInterval(1))
        do {
            try await wait {
                guard let e = try self.ax.unique(anchor, in: self.contentRoot) else { return false }
                return try usable(e)
            }
            stepDeadline = findDeadline
        } catch let error as ScenarioFailure where error.code == "timeout" {
            stepDeadline = findDeadline
            // Submit only after confirming keyboard focus belongs to Find. Without
            // this gate Return can reach the page editor when Notion ignores AX focus.
            guard let raw = ax.get(ax.app, "AXFocusedUIElement"), CFGetTypeID(raw) == AXUIElementGetTypeID(),
                  CFEqual(raw as! AXUIElement, field!) else {
                throw ScenarioFailure("find_focus_lost", "Find did not retain keyboard focus; Return was withheld")
            }
            result.environment["findReturnSubmitted"] = "true"
            ax.key(36)
            // Find can display the query without revealing an unloaded block.
            // Reserve the rest of this replay step for scrolling that document.
            stepDeadline = min(findDeadline, Date().addingTimeInterval(2))
            do {
                try await wait {
                    guard let e = try self.ax.unique(anchor, in: self.contentRoot) else { return false }
                    return try usable(e)
                }
            } catch let error as ScenarioFailure where error.code == "timeout" {
                stepDeadline = findDeadline
                try await closeFind()
                result.environment["anchorLookup"] = "viewport scan after Find"
                if try await scanViewport() { return }
                throw ScenarioFailure("anchor_missing", "Anchor was not exposed by Find or viewport scanning")
            }
        }
        stepDeadline = findDeadline
        try await closeFind()
        try await wait {
            guard let e = try self.ax.unique(anchor, in: self.contentRoot) else { return false }
            return try usable(e) && self.findFields().isEmpty
        }
    }
    private func findFields() -> [AXUIElement] {
        ax.nodes(window).filter { ax.text($0, "AXPlaceholderValue").lowercased().contains("find") }
    }
    private func closeFind() async throws {
        guard !findFields().isEmpty else { return }
        // Escape is scoped to the verified in-page Find field. Do not trust an
        // AXPress on a generically labelled Close button unless disappearance is
        // observed; stale overlays can otherwise steal later page input.
        ax.key(53)
        for _ in 0..<8 {
            try await pause()
            if findFields().isEmpty { return }
        }
        for field in findFields() {
            var parent = ax.parent(field)
            for _ in 0..<4 {
                guard let p = parent else { break }
                if let close = ax.nodes(p).first(where: { ax.text($0, "AXRole") == "AXButton" && ax.text($0, "AXDescription") == "Close" }) {
                    try? ax.press(close)
                    for _ in 0..<8 {
                        try await pause()
                        if findFields().isEmpty { return }
                    }
                    break
                }
                parent = ax.parent(p)
            }
        }
        throw ScenarioFailure("find_not_closed", "Notion's Find overlay remained open after Escape and its Close action")
    }
    private func toggleState(_ anchor: Anchor) throws -> (Bool, AXUIElement) {
        guard let leaf = try ax.unique(anchor, in: contentRoot) else { throw ScenarioFailure("anchor_missing", "Toggle title is not loaded") }
        var current: AXUIElement? = leaf
        for _ in 0..<12 {
            guard let n = current else { break }
            if ax.classes(n).contains("notion-toggle-block") {
                // Only the toggle's own disclosure, not a nested toggle's button.
                if let button = ax.children(n).first(where: { ax.text($0, "AXRole") == "AXButton" }),
                   ax.supports(button, "AXExpanded"), let value = ax.get(button, "AXExpanded") as? NSNumber { return (value.boolValue, button) }
                break
            }
            current = ax.parent(n)
        }
        throw ScenarioFailure("unsupported", "No readable AXExpanded disclosure button for this toggle")
    }
    private func topVisible() throws -> Bool {
        let (_, vp) = try viewport()
        let titles = ax.nodes(contentRoot).filter { node in
            ax.text(node, "AXRole") == "AXTextArea" && ax.text(node, "AXRoleDescription") == "page title"
        }
        return titles.contains { ax.frame($0).map { $0.height > 24 && $0.minY > vp.minY + 2 && $0.maxY < vp.maxY } ?? false }
    }
    private func wheel(_ delta: Int) throws {
        try guardTarget()
        let point = try ax.wheel(delta, viewport: viewport().0)
        result.environment["scrollInputPoint"] = "x=\(point.x) y=\(point.y) screen-top-left-points; AX hit-tested Notion body"
    }
    private func scroll(_ scroll: ScrollRequest) async throws {
        if scroll.mode == "top" {
            let (_, vp) = try viewport()
            if let title = ax.nodes(contentRoot).first(where: { ax.text($0, "AXRoleDescription") == "page title" }) {
                try? ax.press(title, action: "AXScrollToVisible")
            }
            var prior: CGRect?, stable = 0
            while stable < 2 {
                try checkTime()
                try wheel(Int(vp.height.rounded()))
                try await pause()
                let title = ax.nodes(contentRoot).first { ax.text($0, "AXRoleDescription") == "page title" }
                let frame = title.flatMap { ax.frame($0) }
                stable = try topVisible() && frame == prior ? stable + 1 : 0
                prior = frame
            }
            guard let boundary = prior else { throw ScenarioFailure("unsupported", "No visible page title at scroll boundary") }
            result.observedGeometry["topBoundaryCandidate"] = Rect(boundary)
            try wheel(-Int(vp.height.rounded()))
            try await wait {
                let title = self.ax.nodes(self.contentRoot).first { self.ax.text($0, "AXRoleDescription") == "page title" }
                guard let title, let frame = self.ax.frame(title) else { return false }
                self.result.observedGeometry["topMovementProbe"] = Rect(frame)
                return abs(frame.minY - boundary.minY) > 2
            }
            try wheel(Int(vp.height.rounded()))
            try await wait {
                let title = self.ax.nodes(self.contentRoot).first { self.ax.text($0, "AXRoleDescription") == "page title" }
                guard let title, let frame = self.ax.frame(title) else { return false }
                self.result.observedGeometry["topReturnProbe"] = Rect(frame)
                if Rect(boundary).near(Rect(frame)) { return true }
                try self.wheel(Int(vp.height.rounded()))
                return false
            }
            result.observed.scroll = scroll
            result.observedGeometry["topTitle"] = Rect(boundary)
        } else if scroll.mode == "anchor", let anchor = scroll.anchor, let offset = scroll.offset {
            try await locate(anchor)
            try await settleLayout()
            // First measure a fully visible leaf. AXFrame may be clipped at the edge.
            var baselineHeight: CGFloat?
            var stable = 0
            while stable < 2 {
                try checkTime()
                guard let e = try ax.unique(anchor, in: contentRoot), let frame = ax.frame(e) else { throw ScenarioFailure("anchor_missing", "Anchor disappeared while positioning") }
                let (_, vp) = try viewport()
                if frame.height <= 0 { try wheel(100); try await pause(); continue }
                if baselineHeight == nil {
                    if frame.minY <= vp.minY + 2 || frame.maxY >= vp.maxY - 2 {
                        try wheel(-Int(frame.minY - vp.minY - vp.height/2))
                        try await pause(); continue
                    }
                    baselineHeight = frame.height
                    result.observedGeometry["anchorBeforeClipping"] = Rect(frame)
                }
                if offset < 0 {
                    // A clipped frame loses the true origin. Use the fully visible
                    // element's bottom edge and measured full height instead.
                    let inferredTop = frame.maxY - baselineHeight!
                    let error = inferredTop - vp.minY - offset
                    if abs(error) <= 2 && frame.height > 0 && frame.height < baselineHeight! {
                        stable += 1
                    } else {
                        stable = 0
                        try wheel(-Int(error.rounded()))
                    }
                } else {
                    let error = frame.minY - vp.minY - offset
                    if abs(error) <= 2 { stable += 1 }
                    else { stable = 0; try wheel(-Int(error.rounded())) }
                }
                try await pause()
            }
            result.observed.scroll = try observedScroll(anchor: anchor, fullHeight: baselineHeight)
        } else { throw ScenarioFailure("unsupported", "Unknown scroll mode") }
    }
    private var measuredAnchorHeight: CGFloat?
    private func observedScroll(anchor: Anchor, fullHeight: CGFloat? = nil) throws -> ScrollRequest {
        guard let e = try ax.unique(anchor, in: contentRoot), let r = ax.frame(e), r.height > 0 else { throw ScenarioFailure("anchor_missing", "Anchor is not visible") }
        let (_, vp) = try viewport()
        result.observedGeometry["anchor"] = Rect(r)
        result.observedGeometry["viewport"] = Rect(vp)
        if let fullHeight { measuredAnchorHeight = fullHeight }
        let top = (fullHeight ?? measuredAnchorHeight).map { r.maxY - $0 } ?? r.minY
        return ScrollRequest(mode: "anchor", anchor: anchor, offset: top - vp.minY)
    }
    private func focus(_ focus: FocusRequest) async throws {
        if request.scenario.schemaVersion == 1 { ax.key(53) }
        if focus.mode == "clear" {
            // Find can leave Notion's text formatting popover visible after the
            // search field closes. Dismiss that transient selection UI before
            // the final pane-pixel proof; preserve an explicitly requested peek.
            if request.scenario.schemaVersion == 2,
               (request.scenario.state.presentation?.mode ?? "none") == "none",
               request.scenario.state.overlay == nil {
                ax.key(53)
                try await pause()
            }
            parkPointer()
            try await pause()
            // Focus the non-editable page WebArea; verify focus AND empty selection.
            if let editor = ax.editor(contentRoot) {
                var zero = CFRange(location: 0, length: 0)
                try? ax.set(editor, "AXSelectedTextRange", AXValueCreate(.cfRange, &zero)!)
            }
            try ax.set(web, "AXFocused", kCFBooleanTrue)
            try await wait { try self.focusIsClear() }
            result.observed.focus = focus
        } else if focus.mode == "selection", let anchor = focus.anchor, let location = focus.location, let length = focus.length {
            guard let leaf = try ax.unique(anchor, in: contentRoot) else { throw ScenarioFailure("anchor_missing", "Selection anchor must already be loaded; focus cannot change the requested scroll") }
            guard location >= 0, length >= 0, location + length <= anchor.text.utf16.count else { throw ScenarioFailure("invalid_selection", "Selection uses UTF-16 offsets within one source text leaf") }
            try ax.set(leaf, "AXFocused", kCFBooleanTrue)
            var range = CFRange(location: location, length: length)
            try ax.set(leaf, "AXSelectedTextRange", AXValueCreate(.cfRange, &range)!)
            try await wait {
                guard let selected = self.range(leaf) else { return false }
                return selected.location == location && selected.length == length && (self.ax.get(leaf, "AXFocused") as? NSNumber)?.boolValue == true
            }
            result.observed.focus = focus
        } else { throw ScenarioFailure("unsupported", "Only clear focus or a single-leaf UTF-16 selection is supported") }
    }
    private func range(_ e: AXUIElement) -> CFRange? {
        guard let raw = ax.get(e, "AXSelectedTextRange"), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var r = CFRange(); return AXValueGetValue(raw as! AXValue, .cfRange, &r) ? r : nil
    }
    private func focusIsClear() throws -> Bool {
        guard let raw = ax.get(ax.app, "AXFocusedUIElement"), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let focused = raw as! AXUIElement
        result.environment["observedFocusRole"] = ax.text(focused, "AXRole")
        result.environment["observedFocusIsPage"] = String(CFEqual(focused, web))
        guard CFEqual(focused, web) else { return false }
        guard let editor = ax.editor(contentRoot), let selection = range(editor) else { throw ScenarioFailure("unsupported", "Cannot read document selection range") }
        result.environment["observedSelectionUTF16"] = "location=\(selection.location) length=\(selection.length)"
        return selection.length == 0
    }
    private func captureState() async {
        await capturePresentation()
        await step("window") {
            guard let r = self.ax.frame(self.window) else { throw ScenarioFailure("unsupported", "Window frame unavailable") }
            self.result.observed.window = Rect(r)
        }
        await step("sidebar") {
            guard let state = self.sidebar() else { throw ScenarioFailure("unsupported", "Cannot read sidebar state") }
            self.result.observed.sidebarOpen = state.0
        }
        await step("zoom") { throw ScenarioFailure("unsupported", "No public numeric zoom readback; omitted from captured scenario") }
        await step("scroll") {
            // A visible title alone does not prove scrollTop == 0. Capturing
            // never scrolls to probe; save a fully visible source anchor instead.
            let (_, vp) = try self.viewport()
            let candidates = self.ax.leaves(self.contentRoot).filter {
                self.ax.text($0, "AXRoleDescription") != "page title" &&
                (self.ax.frame($0).map { $0.minY > vp.minY + 2 && $0.maxY < vp.maxY - 2 && $0.height > 0 } ?? false)
            }
            guard let first = candidates.first else { throw ScenarioFailure("unsupported", "No fully visible text anchor to save") }
            let anchor = Anchor(text: self.ax.text(first, "AXValue"))
            guard self.ax.matching(anchor, in: self.web).count == 1 else { throw ScenarioFailure("ambiguous_anchor", "Visible text is not unique") }
            self.result.observed.scroll = try self.observedScroll(anchor: anchor)
        }
        await step("toggles") {
            var toggles: [ToggleRequest] = []
            for leaf in self.ax.leaves(self.contentRoot) where self.ax.text(leaf, "AXRoleDescription") == "toggle" {
                guard let frame = self.ax.frame(leaf), frame.height > 0 else { continue }
                let anchor = Anchor(text: self.ax.text(leaf, "AXValue"), blockClass: "notion-toggle-block")
                if let expanded = try? self.toggleState(anchor).0 { toggles.append(ToggleRequest(anchor: anchor, expanded: expanded)) }
            }
            self.result.observed.toggles = toggles
        }
        await step("focus") {
            if try self.focusIsClear() {
                self.result.observed.focus = FocusRequest(mode: "clear")
                return
            }
            let selected = self.ax.leaves(self.mainRoot()).compactMap { leaf -> (Anchor,CFRange)? in
                guard (self.ax.get(leaf,"AXFocused") as? NSNumber)?.boolValue == true,
                      let range = self.range(leaf), range.length > 0 else { return nil }
                let anchor = Anchor(text:self.ax.text(leaf,"AXValue"))
                guard self.ax.matching(anchor,in:self.mainRoot()).count == 1 else { return nil }
                return (anchor,range)
            }
            guard selected.count == 1, let (anchor,range) = selected.first else {
                throw ScenarioFailure("unsupported", "Selection is not one readable, unique main-document text leaf; omitted")
            }
            self.result.observed.focus = FocusRequest(mode:"selection",anchor:anchor,location:range.location,length:range.length)
        }
        await captureSupplementalState()
    }
    private func verifyFinal(item: String = "finalState", includeOverlay: Bool = true) async {
        await step(item) {
            let state = self.request.scenario.state
            if let frame = state.window, !(self.ax.frame(self.window).map { frame.near(Rect($0)) } ?? false) { throw ScenarioFailure("state_drift", "Window changed after application") }
            if includeOverlay, let overlay = state.overlay, ["menu","popup"].contains(overlay.kind) {
                guard self.result.steps.contains(where: { $0.item == "backgroundState" && $0.status == "verified" }), self.overlayVisible(overlay) else {
                    throw ScenarioFailure("state_drift", "Menu or its verified background state is missing")
                }
                self.result.environment["backgroundReadback"] = "Verified before opening modal menu; final readback verifies selected window and open menu. Hidden background AX nodes are not claimed visible."
                return
            }
            if let sidebar = state.sidebarOpen, self.sidebar()?.0 != sidebar { throw ScenarioFailure("state_drift", "Sidebar changed after application") }
            for toggle in state.toggles ?? [] {
                // Missing AX node is not proof of expansion state, even if it was
                // verified earlier. Keep the earlier observation but fail final proof.
                if try self.toggleState(toggle.anchor).0 != toggle.expanded { throw ScenarioFailure("state_drift", "Toggle changed after application") }
            }
            if let scroll = state.scroll {
                guard self.result.steps.contains(where: { $0.item == "scroll" && $0.status == "verified" }) else {
                    throw ScenarioFailure("prerequisite_failed", "Final scroll state cannot be verified because scroll application was not verified")
                }
                if scroll.mode == "top" {
                    let title = self.ax.nodes(self.contentRoot).first { self.ax.text($0, "AXRoleDescription") == "page title" }
                    guard try self.topVisible(), let title, let frame = self.ax.frame(title),
                          let measured = self.result.observedGeometry["topTitle"], measured.near(Rect(frame)) else {
                        throw ScenarioFailure("state_drift", "Document moved from the observed top position")
                    }
                }
                else if let anchor = scroll.anchor, let offset = scroll.offset {
                    let actual = try self.observedScroll(anchor: anchor)
                    guard abs((actual.offset ?? .infinity) - offset) <= 2 else { throw ScenarioFailure("state_drift", "Anchor offset changed after focus application") }
                    self.result.observed.scroll = actual
                }
            }
            if self.request.scenario.schemaVersion == 2 { try await self.verifyScreenState(includeOverlay:includeOverlay) }
            if let focus = state.focus {
                if focus.mode == "clear" {
                    self.result.observed.focus = nil
                    try await self.wait { try self.focusIsClear() }
                    self.result.observed.focus = focus
                }
                else if let a = focus.anchor, let e = try self.ax.unique(a, in: self.contentRoot), let r = self.range(e) {
                    guard r.location == focus.location && r.length == focus.length else { throw ScenarioFailure("state_drift", "Selection changed") }
                } else { throw ScenarioFailure("unsupported", "Cannot verify final selection") }
            }
        }
    }
    private func windowImage() async throws -> (CGImage, CGRect) {
        guard CGPreflightScreenCaptureAccess() else { throw ScenarioFailure("screen_capture_permission", "Enable Screen Recording for Notion Scenarios in System Settings") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try checkTime(); try guardTarget()
        guard let frame = ax.frame(window) else { throw ScenarioFailure("target_window_missing", "Window frame unavailable") }
        let matches = content.windows.filter { $0.owningApplication?.processID == ax.process.processIdentifier && Rect(frame).near(Rect($0.frame)) }
        guard matches.count == 1, let target = matches.first else { throw ScenarioFailure("ambiguous_window", "Cannot uniquely map AX window to capture window") }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        let scale = Double(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try checkTime(); try guardTarget()
        return (image,frame)
    }
    private func screenshot() async throws {
        let (image,frame) = try await windowImage()
        let file = directory.appendingPathComponent("screen.png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ScenarioFailure("capture_failed", "Cannot create PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScenarioFailure("capture_failed", "Cannot save PNG") }
        result.screenshot = CaptureInfo(file: "screen.png", frame: Rect(frame), viewport: try? Rect(viewport().1), pixelWidth: image.width, pixelHeight: image.height,
                                        pixelsPerPointX: Double(image.width) / frame.width, pixelsPerPointY: Double(image.height) / frame.height, capturedAt: now())
        if let region = regionFrame {
            guard let pixels = RegionGeometry.pixels(region: region, window: frame, pixelWidth: image.width, pixelHeight: image.height),
                  let cropped = image.cropping(to: pixels),
                  let output = CGImageDestinationCreateWithURL(directory.appendingPathComponent("region.png") as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ScenarioFailure("capture_failed", "Cannot crop the requested region from the target window capture")
            }
            CGImageDestinationAddImage(output, cropped, nil)
            guard CGImageDestinationFinalize(output) else { throw ScenarioFailure("capture_failed", "Cannot save region.png") }
            let global = CGRect(x: frame.minX + pixels.minX * frame.width / Double(image.width),
                                y: frame.minY + pixels.minY * frame.height / Double(image.height),
                                width: pixels.width * frame.width / Double(image.width), height: pixels.height * frame.height / Double(image.height))
            result.regionScreenshot = CaptureInfo(file: "region.png", frame: Rect(global), viewport: nil, pixelWidth: cropped.width, pixelHeight: cropped.height,
                pixelsPerPointX: Double(image.width) / frame.width, pixelsPerPointY: Double(image.height) / frame.height, capturedAt: now())
        }
        result.environment["capture"] = "ScreenCaptureKit desktopIndependentWindow; excludes other windows and cursor; coordinates screen-top-left-points"
    }
    private func saveDiagnosticScreenshot(_ name: String) async throws {
        let (image, _) = try await windowImage()
        let url = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScenarioFailure("capture_failed", "Cannot create diagnostic screenshot")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScenarioFailure("capture_failed", "Cannot save diagnostic screenshot") }
    }
}

private extension ScenarioRunner {
    var contentRoot: AXUIElement { scopeOverride ?? mainRoot() }

    func peekRoot() -> AXUIElement? {
        ax.nodes(web).first { ax.classes($0).contains("notion-peek-renderer") }
    }
    func mainRoot() -> AXUIElement {
        let peek = peekRoot()
        let candidates = ax.nodes(web).filter { node in !(peek.map { ax.contains($0, node) } ?? false) }
        return candidates.first { ax.classes($0).contains("notion-frame") }
            ?? candidates.first { ax.classes($0).contains("whenContentEditable") } ?? web
    }
    func root(_ scope: String) throws -> AXUIElement {
        if scope == "preview" {
            guard let peek = peekRoot() else { throw ScenarioFailure("preview_missing", "Requested preview is not open") }
            return peek
        }
        if scope == "sidebar" {
            let candidates = ax.nodes(window).filter {
                (ax.classes($0).contains("notion-sidebar-container") || ax.classes($0).contains("notion-sidebar")) &&
                (ax.frame($0).map { $0.width > 2 && $0.height > 2 } ?? false)
            }
            guard let node = candidates.first(where: { ax.classes($0).contains("notion-sidebar") }) ?? candidates.first else {
                throw ScenarioFailure("unsupported", "Notion does not expose a recognizable sidebar container")
            }
            return node
        }
        return mainRoot()
    }
    func scopedViewport(_ scope: String, container: Anchor? = nil, axis: String = "y") throws -> (AXUIElement, CGRect) {
        let source = try root(scope)
        if scope == "database", axis == "y", let viewport = ax.viewport(source), let frame = ax.frame(viewport) {
            let names = Set(request.databasePropertyNames ?? [])
            let headers = ax.nodes(source).filter { ax.text($0, "AXRole") == "AXPopUpButton" && names.contains(ax.label($0)) }
                .compactMap { ax.frame($0) }.filter { $0.height > 0 && $0.intersects(frame) }
            let top = max(frame.minY, headers.map { $0.maxY }.max() ?? frame.minY)
            return (viewport, CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - top)))
        }
        if scope == "database", axis == "x" {
            let candidates = ax.nodes(source).filter { ax.classes($0).contains("notion-collection-view-body") && ax.classes($0).contains("horizontal") }
            if candidates.count == 1, let candidate = candidates.first, let frame = ax.frame(candidate) { return (candidate, frame) }
        }
        if ["main", "preview"].contains(scope), let viewport = ax.viewport(source), let frame = ax.frame(viewport) {
            return (viewport, frame)
        }
        if scope == "table", axis == "x", container == nil {
            let candidates = ax.nodes(source).filter { node in
                ax.classes(node).contains("notion-scroller") && ax.classes(node).contains("horizontal") &&
                (ax.frame(node).map { $0.width > 2 && $0.height > 2 } ?? false) &&
                ax.nodes(node).contains { ax.text($0,"AXRole") == "AXTable" }
            }
            if candidates.count == 1, let candidate = candidates.first, let frame = ax.frame(candidate) { return (candidate,frame) }
        }
        var seed: AXUIElement? = source
        if scope == "code" {
            seed = try codeBlock(container: container)
        } else if let container {
            seed = try ax.unique(container, in: source)
            guard seed != nil else { throw ScenarioFailure("anchor_missing", "Scroll container anchor is not loaded") }
        } else if scope == "database" {
            seed = ax.nodes(source).first { n in ax.classes(n).contains(where: { $0.hasPrefix("notion-collection") }) }
        } else if scope == "code" || scope == "table" {
            seed = ax.nodes(source).first { ax.classes($0).contains(scope == "code" ? "notion-code-block" : "notion-table-block") }
        }
        guard let seed else { throw ScenarioFailure("unsupported", "Requested scroll container is unavailable") }
        let direction = axis == "x" ? "horizontal" : "vertical"
        var current: AXUIElement? = seed
        for _ in 0..<30 {
            guard let n = current else { break }
            if ax.classes(n).contains("notion-scroller"), ax.classes(n).contains(direction), let frame = ax.frame(n), frame.width > 0, frame.height > 0 {
                return (n, frame)
            }
            current = ax.parent(n)
        }
        let candidates = ax.nodes(seed).filter {
            ax.classes($0).contains("notion-scroller") && ax.classes($0).contains(direction) && (ax.frame($0).map { $0.width > 0 && $0.height > 0 } ?? false)
        }
        if scope == "code", axis == "x" {
            let probe = (Int(result.environment["codeViewportProbeCount"] ?? "0") ?? 0) + 1
            result.environment["codeViewportProbeCount"] = String(probe)
            func rect(_ node: AXUIElement) -> String {
                guard let r = ax.frame(node) else { return "no-frame" }
                return "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))"
            }
            var ancestors: [String] = []
            var node: AXUIElement? = seed
            for _ in 0..<8 {
                guard let current = node else { break }
                let classes = ax.classes(current).filter { $0.contains("notion") || $0.contains("horizontal") || $0.contains("code") }
                ancestors.append("\(classes.joined(separator: ","))@\(rect(current))")
                node = ax.parent(current)
            }
            let blocks = ax.nodes(source).filter { ax.classes($0).contains("notion-code-block") }
            let candidateSummary = candidates.map { "\(ax.classes($0).joined(separator: ","))@\(rect($0))" }
            result.environment["codeViewportProbe.\(probe)"] = "codeBlocks=\(blocks.count);seed=\(rect(seed));ancestors=[\(ancestors.joined(separator: " | "))];horizontalCandidates=\(candidates.count)[\(candidateSummary.joined(separator: " | "))]"
        }
        if scope == "code", axis == "x", candidates.isEmpty,
           let frame = ax.frame(seed), frame.width >= 100, frame.height >= 40 {
            result.environment["codeHorizontalTarget"] = "No horizontal scroller node exposed; using the uniquely anchored outer code block frame as the wheel and pixel-proof region"
            return (seed, frame)
        }
        guard candidates.count == 1, let candidate = candidates.first, let frame = ax.frame(candidate) else {
            throw ScenarioFailure("unsupported", "Cannot uniquely identify \(scope) \(direction) viewport")
        }
        return (candidate, frame)
    }
    func control(_ label: String, in source: AXUIElement) throws -> AXUIElement {
        let hits = ax.nodes(source).filter { node in
            ["AXButton", "AXPopUpButton", "AXMenuItem", "AXRadioButton", "AXTab"].contains(ax.text(node, "AXRole")) && ax.label(node) == label &&
            (ax.frame(node).map { $0.width > 2 && $0.height > 2 } ?? false)
        }
        guard hits.count == 1, let hit = hits.first else {
            let candidates = hits.prefix(6).map { node in
                let frame = ax.frame(node).map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "no-frame"
                return "\(ax.text(node, "AXRole"))@\(frame) selected=\(String(describing:selected(node))) classes=\(ax.classes(node).joined(separator:","))"
            }.joined(separator:";")
            throw ScenarioFailure("unsupported", "Cannot uniquely identify UI control: \(label) (matches=\(hits.count): \(candidates))")
        }
        return hit
    }
    func activate(_ element: AXUIElement) throws {
        do { try ax.press(element) }
        catch let error as ScenarioFailure where error.code == "unsupported" { try ax.click(element) }
    }
    func menuText(_ prefix: String) -> AXUIElement? {
        let matches = ax.nodes(web).filter {
            ["AXStaticText", "AXMenuItem"].contains(ax.text($0, "AXRole")) &&
            (ax.label($0) == prefix || ax.label($0).hasPrefix(prefix + " "))
        }
        return matches.count == 1 ? matches[0] : nil
    }
    func previewIdentity() -> (id: String, mode: String)? {
        guard let peek = peekRoot(), let link = ax.nodes(peek).first(where: { ax.text($0, "AXDescription") == "Open in full page" }),
              let id = NotionPageURL.id(from: ax.url(link)) else { return nil }
        let url = URLComponents(string: ax.url(web))
        let mode = url?.queryItems?.first(where: { $0.name == "pm" })?.value
        return (id, mode == "s" ? "side" : mode == "c" ? "center" : "unknown")
    }
    private func revealPeekModeControl(in peek: AXUIElement) async throws -> AXUIElement {
        let peekFrame = ax.frame(peek)
        let header = ax.nodes(peek).first { ax.classes($0).contains("peek-top-hover-area") }
        guard let headerFrame = header.flatMap({ ax.frame($0) }) ?? peekFrame.map({
            CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: min(44, $0.height))
        }), headerFrame.width > 0, headerFrame.height > 0 else {
            throw ScenarioFailure("unsupported", "Side peek header is not exposed for mode switching")
        }
        // Notion reveals the half-window mode button only while the peek header
        // is hovered. Hover its leading control area first; the adjacent `»`
        // control closes the side peek and is not the mode switch.
        let x = headerFrame.minX + min(92, headerFrame.width * 0.12)
        ax.move(CGPoint(x: x, y: headerFrame.midY))
        try await pause()
        let button = try control("Switch peek mode", in: peek)
        guard let frame = ax.frame(button), frame.width > 0, frame.height > 0,
              frame.intersects(headerFrame.insetBy(dx: -2, dy: -2)) else {
            throw ScenarioFailure("unsupported", "Hover did not expose the Switch peek mode control in the side peek header")
        }
        result.environment["peekModeControl"] = "Header hovered; Switch peek mode selected, not the adjacent close control"
        return button
    }
    func applyPresentation(_ p: PresentationRequest) async throws {
        result.environment["presentation.phase"] = "inspect current preview"
        if p.mode == "none" {
            try await dismissPreview()
            result.observed.presentation = p
            return
        }
        guard let id = request.previewPageId else { throw ScenarioFailure("invalid_request", "Preview target was not resolved from local Fixture state") }
        if previewIdentity()?.id != id {
            result.environment["presentation.phase"] = "locate registered record"
            if peekRoot() != nil { try await dismissPreview() }
            let links = ax.nodes(mainRoot()).filter { ax.text($0, "AXRole") == "AXLink" && NotionPageURL.id(from: ax.url($0)) == id }
            if let link = links.first {
                result.environment["presentation.phase"] = "open database page-link actions menu"
                try? ax.press(link, action: "AXScrollToVisible")
                try await pause()
                guard let frame = ax.frame(link), frame.height > 0 else { throw ScenarioFailure("anchor_missing", "Preview link is outside the loaded visible content") }
                do { try ax.press(link, action: "AXShowMenu") }
                catch let error as ScenarioFailure where error.code == "unsupported" { try ax.rightClick(link) }
                try await wait { self.menuText("Open in side peek") != nil || self.menuText("Open in") != nil }
                if let direct = menuText("Open in side peek") {
                    result.environment["presentation.phase"] = "select direct Open in side peek menu item"
                    try ax.click(direct)
                } else {
                    result.environment["presentation.phase"] = "expand page-link Open in submenu"
                    try ax.click(menuText("Open in")!)
                    result.environment["presentation.phase"] = "select page-link Side peek menu item"
                    try await wait { self.menuText("Side peek") != nil }
                    try ax.click(menuText("Side peek")!)
                }
            } else {
                // Database rows expose their page URL on the row's Open button or link.
                result.environment["presentation.phase"] = "match database record row"
                guard let title = request.previewTitle else { throw ScenarioFailure("invalid_request", "Preview title is missing") }
                func normalized(_ value: String) -> String { value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
                let needsNote = (request.pageReferences ?? []).filter { $0.fixtureId == request.scenario.fixtureId && $0.rowIndex != nil && $0.title == title }.count > 1
                let rowCandidates = ax.nodes(mainRoot()).filter { node in
                    guard ax.classes(node).contains("notion-collection-item") else { return false }
                    let values = ax.nodes(node).map { ax.label($0) }
                    return values.contains(title) && (!needsNote || (request.previewRowText.map { note in values.contains { normalized($0) == normalized(note) } } ?? false))
                }
                // Some database views expose both a card and one or more nested
                // collection-item wrappers for that same record. Keep the
                // deepest matching row so the same visible card is not counted
                // multiple times.
                let rows = rowCandidates.filter { candidate in
                    !rowCandidates.contains { other in
                        !CFEqual(candidate, other) && ax.contains(candidate, other)
                    }
                }
                result.environment["presentation.rowCandidates"] = "raw=\(rowCandidates.count), deepest=\(rows.count)"
                guard rows.count == 1, let row = rows.first else { throw ScenarioFailure("unsupported", "No uniquely identified record row is exposed: \(title)") }
                let titles = ax.nodes(row).filter { node in
                    ax.text(node,"AXRole") == "AXButton" &&
                    (ax.label(node) == title || ax.nodes(node).contains { ax.text($0,"AXRole") == "AXStaticText" && ax.label($0) == title })
                }
                let titleButtons = titles.filter { candidate in !titles.contains { other in !CFEqual(candidate,other) && ax.contains(candidate,other) } }
                guard titleButtons.count == 1, let titleButton = titleButtons.first else { throw ScenarioFailure("unsupported", "Record title control is ambiguous") }
                result.environment["presentation.phase"] = "open record actions menu"
                try? ax.press(titleButton, action: "AXScrollToVisible")
                try await wait { self.ax.frame(titleButton).map { $0.height > 2 && $0.width > 2 } ?? false }
                do { try ax.press(titleButton, action: "AXShowMenu") }
                catch let error as ScenarioFailure where error.code == "unsupported" { try ax.rightClick(titleButton) }
                try await wait { self.menuText("Open in") != nil }
                try ax.click(menuText("Open in")!)
                result.environment["presentation.phase"] = "select side peek menu item"
                try await wait { self.menuText("Side peek") != nil }
                try ax.click(menuText("Side peek")!)
            }
            result.environment["presentation.phase"] = "wait for side preview"
            try await wait { self.previewIdentity()?.id == id }
        }
        try await wait { self.peekRoot().flatMap { self.ax.editor($0) } != nil }
        if p.mode == "full" {
            result.environment["presentation.phase"] = "find open-in-full-page control"
            guard let peek = peekRoot() else { throw ScenarioFailure("preview_missing", "Preview unavailable") }
            let links = ax.nodes(peek).filter { ax.text($0, "AXDescription") == "Open in full page" }
            guard let link = links.first else { throw ScenarioFailure("unsupported", "Open in full page is unavailable") }
            result.environment["presentation.phase"] = "open full page"
            try activate(link)
            var opened = false
            for _ in 0..<8 {
                if ax.isPage(web, pageId: id) && peekRoot() == nil { opened = true; break }
                try await pause()
            }
            if !opened { try ax.click(link) }
            result.environment["presentation.phase"] = "verify full page"
            try await wait { self.ax.isPage(self.web, pageId: id) && self.peekRoot() == nil }
        } else if previewIdentity()?.mode != p.mode {
            guard let peek = peekRoot() else { throw ScenarioFailure("preview_missing", "Preview unavailable") }
            let switchButton = try await revealPeekModeControl(in: peek)
            try ax.click(switchButton)
            let label = p.mode == "side" ? "Side peek" : "Center peek"
            try await wait { (try? self.control(label, in: self.web)) != nil }
            try ax.click(control(label, in: web))
            try await wait { self.previewIdentity()?.mode == p.mode }
        }
        if let fraction = p.widthFraction, p.mode == "side" {
            guard let peek = peekRoot(), let frame = ax.frame(peek), let page = ax.frame(web),
                  let splitter = ax.nodes(peek).first(where: { ax.text($0, "AXRole") == "AXSplitter" }), let handle = ax.frame(splitter) else {
                throw ScenarioFailure("unsupported", "Side peek does not expose a resize splitter")
            }
            let desired = page.width * fraction
            if abs(frame.width - desired) > 2 {
                try await ax.drag(from: CGPoint(x: handle.minX, y: handle.midY),
                                  to: CGPoint(x: page.maxX - desired, y: handle.midY))
                try await pause()
                if let current = peekRoot().flatMap({ ax.frame($0) }), abs(current.width - frame.width) < 0.5 {
                    throw ScenarioFailure("unsupported", "Requested peek width is outside Notion's observed resize range or the resize handle did not respond")
                }
            }
            try await wait { self.peekRoot().flatMap { self.ax.frame($0) }.map { abs($0.width - desired) <= 2 } ?? false }
        }
        result.observed.presentation = p
        if let peek = peekRoot(), let frame = ax.frame(peek) { result.observedGeometry["preview"] = Rect(frame) }
        result.environment["previewPageId"] = id
    }
    func dismissPreview() async throws {
        guard let peek = peekRoot() else { return }
        if let button = try? control("Close",in:peek) { try ax.click(button); try await pause() }
        if peekRoot() != nil {
            try ax.set(web,"AXFocused",kCFBooleanTrue)
            for _ in 0..<3 {
                guard peekRoot() != nil else { break }
                ax.key(53); try await pause()
            }
        }
        try await wait { self.peekRoot() == nil }
    }
    func setSidebarPinned(_ open: Bool) async throws {
        guard let current = sidebar() else { throw ScenarioFailure("unsupported", "Sidebar button is unavailable") }
        guard current.0 != open else { return }
        try activate(current.1)
        try await pause()
        if let state = sidebar(), state.0 != open { try ax.click(state.1) }
        try await wait { self.sidebar()?.0 == open }
    }
    func applySidebar(_ desired: SidebarRequest) async throws {
        // The floating pane dismisses when its resize gesture leaves the hover
        // area. Set its shared width while pinned, then reveal it by hovering.
        if desired.mode == "floating", let width = desired.width,
           (try? root("sidebar")).flatMap({ ax.frame($0) }).map({ abs($0.width - width) > 2 }) ?? true {
            try await applySidebar(SidebarRequest(mode: "pinned", width: width))
            try await setSidebarPinned(false)
        }
        guard let current = sidebar() else { throw ScenarioFailure("unsupported", "Sidebar toggle is unavailable") }
        if current.0 != (desired.mode == "pinned") { try await setSidebarPinned(desired.mode == "pinned") }
        if desired.mode == "floating" {
            guard let state = sidebar(), let rect = ax.frame(state.1) else { throw ScenarioFailure("unsupported", "Sidebar hover target unavailable") }
            if let page = ax.frame(web) {
                ax.move(CGPoint(x: page.midX, y: page.minY + 60))
                try await pause()
            }
            ax.move(CGPoint(x: rect.midX, y: rect.midY))
        } else if desired.mode == "closed", let frame = ax.frame(web) {
            ax.move(CGPoint(x: frame.maxX - 5, y: frame.minY + 60))
        }
        try await wait {
            if desired.mode == "floating" { return self.sidebar()?.0 == false && (try? self.root("sidebar")) != nil }
            if desired.mode == "closed" { return self.sidebar()?.0 == false && (try? self.root("sidebar")) == nil }
            return self.sidebar()?.0 == (desired.mode == "pinned")
        }
        if let width = desired.width {
            let source = try root("sidebar")
            guard let frame = ax.frame(source) else { throw ScenarioFailure("unsupported", "Sidebar frame unavailable") }
            result.observedGeometry["sidebarBeforeResize"] = Rect(frame)
            if abs(frame.width - width) > 2 {
                let handles = ax.nodes(source).filter { ax.text($0, "AXRole") == "AXSplitter" }
                let handle = handles.first.flatMap { ax.frame($0) }
                let origin = CGPoint(x: handle?.minX ?? (frame.maxX - 1), y: handle?.midY ?? frame.midY)
                try await ax.drag(from: origin, to: CGPoint(x: frame.minX + width - 1, y: origin.y))
                try await pause()
                if let observed = try? root("sidebar"), let actual = ax.frame(observed), abs(actual.width - frame.width) < 0.5 {
                    result.observedGeometry["sidebarAfterResize"] = Rect(actual)
                    throw ScenarioFailure("unsupported", "Sidebar resize edge did not respond")
                }
            }
            try await wait { (try? self.root("sidebar")).flatMap { self.ax.frame($0) }.map { abs($0.width - width) <= 2 } ?? false }
        }
        result.observed.sidebar = desired
    }
    func selected(_ element: AXUIElement) -> Bool? {
        if ["AXRadioButton", "AXCheckBox", "AXTab"].contains(ax.text(element, "AXRole")), let value = ax.get(element, "AXValue") as? NSNumber { return value.boolValue }
        if let value = ax.get(element, "AXSelected") as? NSNumber { return value.boolValue }
        return nil
    }
    func currentDatabaseView() -> String? {
        let groups = ax.nodes(mainRoot()).filter { ax.text($0, "AXRole") == "AXTabGroup" }
        for group in groups {
            let buttons = ax.nodes(group).filter { ["AXPopUpButton", "AXRadioButton", "AXTab", "AXButton"].contains(ax.text($0, "AXRole")) }
            if let current = buttons.first(where: { selected($0) == true }) { result.environment["databaseViewPicker"] = "tabs"; return ax.label(current) }
            if buttons.count == 1, let current = buttons.first, request.databaseViewNames?.contains(ax.label(current)) == true { result.environment["databaseViewPicker"] = "dropdown"; return ax.label(current) }
        }
        return nil
    }
    func selectDatabaseView(_ name: String) async throws {
        // Preparation runs after any peek is closed. Clear row selection and
        // lingering view menus before looking for the view picker.
        try ax.set(web,"AXFocused",kCFBooleanTrue)
        ax.key(53); try await pause()
        try await wait { self.ax.editor(self.mainRoot()) != nil }
        let visible = ax.nodes(mainRoot()).contains { ax.text($0,"AXRole") == "AXTabGroup" && (ax.frame($0).map { $0.height > 10 } ?? false) }
        if !visible, let viewport = ax.viewport(mainRoot()) {
            try ax.wheel(100_000,viewport:viewport)
            try await pause()
        }
        var current: String?
        try await wait { current = self.currentDatabaseView(); return current != nil }
        if current != name {
            if let target = try? tabControl(name,in:mainRoot()), ax.frame(target).map({ $0.height > 10 && $0.width > 10 }) == true {
                if selected(target) != true { try ax.click(target) }
            } else {
                let overflow = ax.nodes(mainRoot()).filter { node in
                    ax.text(node,"AXRole") == "AXPopUpButton" &&
                    ax.label(node).range(of:"^[0-9]+ more…$",options:.regularExpression) != nil &&
                    (ax.frame(node).map { $0.width > 10 && $0.height > 10 } ?? false)
                }
                let compact = ax.nodes(mainRoot()).filter { node in
                    ax.text(node,"AXRole") == "AXPopUpButton" && ax.label(node) == current &&
                    (ax.frame(node).map { $0.width > 10 && $0.height > 10 } ?? false)
                }
                let choices = overflow.count == 1 ? overflow : compact
                guard choices.count == 1, let button = choices.first else { throw ScenarioFailure("unsupported", "View is hidden and no unique tab overflow or compact picker is exposed") }
                try ax.click(button)
                var field: AXUIElement?
                try await wait {
                    field = self.ax.nodes(self.web).first { self.ax.text($0, "AXRole") == "AXComboBox" && self.ax.text($0, "AXPlaceholderValue") == "Search for a view..." }
                    return field != nil
                }
                try ax.set(field!, "AXFocused", kCFBooleanTrue)
                try ax.set(field!, "AXValue", name as CFString)
                try await wait {
                    self.ax.text(field!, "AXValue") == name && self.ax.nodes(self.web).contains {
                        self.ax.text($0, "AXRole") == "AXStaticText" && self.ax.label($0).hasPrefix(name + " Database view settings")
                    }
                }
                ax.key(36)
            }
        }
        try await wait { self.currentDatabaseView() == name }
        result.observed.databaseView = name
    }
    func applyTab(_ tab: TabRequest) async throws {
        let source = try root(tab.scope)
        scopeOverride = source; defer { scopeOverride = nil }
        try await locate(tab.anchor)
        let button = try tabControl(tab.selectedText, in: source)
        try? ax.press(button,action:"AXScrollToVisible")
        try await pause()
        if selected(button) != true { try ax.click(button) }
        if let content = try ax.unique(tab.contentAnchor,in:source) {
            try? ax.press(content,action:"AXScrollToVisible")
        }
        try await wait {
            guard let leaf = try self.ax.unique(tab.contentAnchor, in: source), let frame = self.ax.frame(leaf) else { return false }
            return frame.height > 0 && frame.width > 0
        }
    }
    func tabControl(_ text: String, in source: AXUIElement) throws -> AXUIElement {
        let matches = ax.nodes(source).filter { node in
            ["AXTab", "AXRadioButton"].contains(ax.text(node, "AXRole")) &&
            (ax.label(node) == text || ax.nodes(node).contains { ax.text($0, "AXRole") == "AXStaticText" && ax.label($0) == text })
        }
        guard matches.count == 1, let tab = matches.first else { throw ScenarioFailure("unsupported", "Cannot uniquely identify authored tab: \(text)") }
        return tab
    }
    func applyBlockDisplay(_ display: BlockDisplayRequest) async throws {
        guard request.allowPersistentPresentation == true else {
            throw ScenarioFailure("persistent_presentation_unsupported", "Mermaid display switching is allowed only on a managed mutable-presentation sandbox")
        }
        let block = try displayBlock(display, in: root(display.scope))
        if blockDisplayMatches(display, in: block) { return }
        try await revealBlockControls(block)
        guard let popup = ax.nodes(block).first(where: {
            ax.text($0, "AXRole") == "AXPopUpButton" && ax.text($0, "AXDescription").contains("preview format dropdown")
        }) else { throw ScenarioFailure("unsupported", "Mermaid preview format dropdown is unavailable") }
        try ax.click(popup)
        let optionDescription: String
        switch display.mode {
        case "source": optionDescription = "Show only code and hide preview"
        case "diagram": optionDescription = "Show only preview and hide code"
        default: throw ScenarioFailure("unsupported", "Unsupported Mermaid display mode: \(display.mode)")
        }
        let option = try await waitForBlockDisplayOption(optionDescription)
        try ax.click(option)
        try await wait {
            guard let current = try? self.displayBlock(display, in: self.root(display.scope)) else { return false }
            return self.blockDisplayMatches(display, in: current)
        }
    }
    func waitForBlockDisplayOption(_ description: String) async throws -> AXUIElement {
        for _ in 0..<12 {
            if let option = ax.nodes(web).first(where: {
                ax.text($0, "AXRole") == "AXButton" && ax.text($0, "AXDescription") == description
            }) { return option }
            try await pause()
        }
        throw ScenarioFailure("unsupported", "Mermaid preview option is unavailable: \(description)")
    }
    func blockDisplayMatches(_ display: BlockDisplayRequest, in block: AXUIElement) -> Bool {
        let nodes = ax.nodes(block)
        let codeVisible = nodes.contains { node in
            ax.text(node, "AXRole") == "AXTextArea" && !ax.text(node, "AXValue").isEmpty &&
            (ax.frame(node).map { $0.width > 0 && $0.height > 0 } ?? false)
        }
        let diagramVisible = nodes.contains { node in
            ax.text(node, "AXRole") == "AXButton" && ax.text(node, "AXDescription") == "Click diagram to expand in fullscreen" &&
            (ax.frame(node).map { $0.width > 0 && $0.height > 0 } ?? false)
        }
        switch display.mode {
        case "source": return codeVisible && !diagramVisible
        case "diagram": return diagramVisible && !codeVisible
        default: return false
        }
    }
    func revealBlockControls(_ block: AXUIElement) async throws {
        guard let frame = ax.frame(block), frame.width > 0, frame.height > 0 else {
            throw ScenarioFailure("unsupported", "Mermaid block has no visible frame")
        }
        ax.move(CGPoint(x: frame.maxX - 12, y: frame.minY + 12))
        try await Task.sleep(for: .milliseconds(250))
    }
    func displayBlock(_ display: BlockDisplayRequest, in source: AXUIElement) throws -> AXUIElement {
        guard let leaf = try ax.unique(display.anchor, in: source) else { throw ScenarioFailure("anchor_missing", "Diagram anchor is missing") }
        var node: AXUIElement? = leaf
        var block: AXUIElement?
        for _ in 0..<15 {
            guard let current = node else { break }
            if ax.classes(current).contains("notion-code-block") { block = current; break }
            node = ax.parent(current)
        }
        if block == nil {
            let nodes = ax.nodes(source)
            if let index = nodes.firstIndex(where: { CFEqual($0, leaf) }) {
                block = nodes.dropFirst(index + 1).first { ax.classes($0).contains("notion-code-block") }
            }
        }
        guard let block else { throw ScenarioFailure("unsupported", "Diagram controls are not exposed around the source anchor") }
        return block
    }
    func prepareScreenState() async {
        let state = request.scenario.state
        if state.databaseView != nil, peekRoot() != nil {
            await step("previewReset") { try await self.applyPresentation(PresentationRequest(mode: "none")) }
        }
        if let view = state.databaseView { await step("databaseView") { try await self.selectDatabaseView(view) } }
        if let desired = state.sidebar { await step("sidebar") { try await self.applySidebar(desired) } }
        if state.presentation?.mode == "center" {
            if peekRoot() != nil { await step("previewReset") { try await self.applyPresentation(PresentationRequest(mode:"none")) } }
            // The center peek covers body input points. Set the background
            // before opening it, then prove its final geometry after capture.
            for (index, scroll) in (state.scrolls ?? []).enumerated() where scroll.scope == "main" {
                await step("scroll.\(index)") { try await self.scopedScroll(scroll,index:index) }
            }
            await step("backgroundState") {
                for (index, scroll) in (state.scrolls ?? []).enumerated() where scroll.scope == "main" {
                    guard self.result.steps.contains(where: { $0.item == "scroll.\(index)" && $0.status == "verified" }) else {
                        throw ScenarioFailure("prerequisite_failed", "Center peek background scroll was not verified")
                    }
                }
            }
        }
        if let presentation = state.presentation { await step("presentation") { try await self.applyPresentation(presentation) } }
        // Opening a DB record preview can make Notion collapse its sidebar after
        // the earlier layout pass. Reassert the requested state against the final
        // two-pane layout before positioning either viewport.
        if let desired = state.sidebar, desired.mode != "floating" {
            await step("sidebar.afterPresentation") { try await self.applySidebar(desired) }
        }
        for (index, tab) in (state.tabs ?? []).enumerated() {
            await step("tab.\(index)") { try await self.applyTab(tab) }
        }
        result.observed.tabs = state.tabs
    }
    private func applyBlockDisplays() async {
        for (index, display) in (request.scenario.state.blockDisplays ?? []).enumerated() {
            await step("blockDisplay.\(index)") { try await self.applyBlockDisplay(display) }
        }
        result.observed.blockDisplays = request.scenario.state.blockDisplays
    }
    func scrollFrame(_ scroll: ViewportScrollRequest, source: AXUIElement) throws -> CGRect? {
        guard let anchor = scroll.anchor, let element = try ax.unique(anchor, in: source) else { return nil }
        if let location = scroll.rangeLocation, let length = scroll.rangeLength {
            var targets: [(AXUIElement, Int)] = [(element,location)]
            if let editor = ax.editor(source) {
                let text = ax.text(editor,"AXValue") as NSString
                let match = text.range(of:anchor.text)
                if match.location != NSNotFound, text.range(of:anchor.text,range:NSRange(location:match.location+match.length,length:text.length-match.location-match.length)).location == NSNotFound {
                    targets.append((editor,match.location+location))
                }
            }
            for (target, start) in targets {
                var range = CFRange(location:start,length:length)
                var value: CFTypeRef?
                guard let parameter = AXValueCreate(.cfRange,&range) else { continue }
                let status = AXUIElementCopyParameterizedAttributeValue(target,"AXBoundsForRange" as CFString,parameter,&value)
                result.environment["rangeBounds.\(start).status"] = String(status.rawValue)
                result.environment["rangeBounds.\(start).value"] = value.map { String(describing:$0) } ?? "nil"
                guard status == .success,
                      let value, CFGetTypeID(value) == AXValueGetTypeID() else { continue }
                var rect = CGRect.zero
                if AXValueGetValue(value as! AXValue,.cgRect,&rect), rect.width > 0, rect.height > 0 { return rect }
            }
            if let rect = try markerBounds(element:element,text:anchor.text,location:location,length:length) { return rect }
            throw ScenarioFailure("unsupported", "Neither range API exposes bounds for the requested source-verified UTF-16 range")
        }
        if scroll.scope == "database", scroll.axis == "x",
           anchor.blockClass == "notion-timeline-item-properties",
           ax.text(element, "AXRole") == "AXStaticText" {
            // The pinned list clamps the AXFrame of a covered timeline label.
            // Position replay with Chromium's unclipped text-range coordinates
            // so an anchor can converge underneath the pinned panel as requested.
            var range = CFRange(location: 0, length: anchor.text.utf16.count)
            var value: CFTypeRef?
            if let parameter = AXValueCreate(.cfRange, &range),
               AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForRange" as CFString, parameter, &value) == .success,
               let value, CFGetTypeID(value) == AXValueGetTypeID() {
                var bounds = CGRect.zero
                if AXValueGetValue(value as! AXValue, .cgRect, &bounds),
                   bounds.width > 0, bounds.height > 0, !bounds.isInfinite {
                    result.environment["timelineHorizontalAnchorBounds"] = "AXBoundsForRange; unclipped full source"
                    return bounds
                }
            }
        }
        return ax.frame(element)
    }
    func markerBounds(element: AXUIElement, text: String, location: Int, length: Int) throws -> CGRect? {
        // These parameterized attributes are advertised by Notion's AX tree.
        // Opaque markers stay in memory; no private marker constructors or IDs.
        func parameter(_ name: String,_ value: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(web,name as CFString,value,&result) == .success ? result : nil
        }
        func between(_ start: CFTypeRef,_ end: CFTypeRef) -> CFTypeRef? {
            parameter("AXTextMarkerRangeForUnorderedTextMarkers",[start,end] as CFArray)
        }
        let key = "\(location):\(length):\(text)"
        var requested = markerRanges[key]
        if requested == nil, let start = ax.get(element,"AXStartTextMarker") {
            let original = text as NSString
            var cursor = start, offset = 0
            var beginning: CFTypeRef? = location == 0 ? start : nil
            for iteration in 0..<(original.length*2+4) {
                if iteration % 16 == 0 { try checkTime() }
                if offset == location { beginning = cursor }
                if offset == location+length, let beginning,
                   let range = between(beginning,cursor), let actual = parameter("AXStringForTextMarkerRange",range) as? String,
                   actual == original.substring(with:NSRange(location:location,length:length)) {
                    requested = range; markerRanges[key] = range; break
                }
                guard offset < location+length,
                      let next = parameter("AXNextTextMarkerForTextMarker",cursor), !CFEqual(next,cursor),
                      let prefixRange = between(start,next), let prefix = parameter("AXStringForTextMarkerRange",prefixRange) as? String,
                      prefix.utf16.count > offset, prefix.utf16.count <= original.length,
                      prefix == original.substring(to:prefix.utf16.count) else { break }
                cursor = next; offset = prefix.utf16.count
            }
        }
        guard let requested, let value = parameter("AXBoundsForTextMarkerRange",requested), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue,.cgRect,&rect), rect.width > 0, rect.height > 0 else { return nil }
        result.environment["rangeBounds.method"] = "AXBoundsForTextMarkerRange; exact source substring checked with AXStringForTextMarkerRange"
        return rect
    }
    func scopedScroll(_ scroll: ViewportScrollRequest, index: Int) async throws {
        let source = try root(scroll.scope)
        scopeOverride = source; defer { scopeOverride = nil }
        let hasTimelinePosition = (request.scenario.state.scrolls ?? []).contains {
            $0.scope == "database" && $0.axis == "x" && $0.anchor?.blockClass == "notion-timeline-item-properties"
        }
        if hasTimelinePosition, scroll.scope == "database", scroll.axis == "y",
           scroll.anchor?.blockClass == "notion-collection-item" {
            try await activateTimelineToday(in: source)
        }
        if let container = scroll.container { try await locate(container) }
        if let anchor = scroll.anchor, scroll.scope == "main" || scroll.scope == "preview" || (scroll.scope == "database" && scroll.axis == "y") { try await locate(anchor) }
        if scroll.scope == "code" { try await hoverCodeBlock(container: scroll.container) }
        var viewport: AXUIElement
        var bounds: CGRect
        do {
            (viewport, bounds) = try scopedViewport(scroll.scope, container: scroll.container, axis: scroll.axis)
        } catch let error as ScenarioFailure where scroll.scope == "code" && error.code == "unsupported" {
            try await primeCodeHorizontalScroll(container: scroll.container)
            (viewport, bounds) = try scopedViewport(scroll.scope, container: scroll.container, axis: scroll.axis)
        }
        result.observedGeometry["scroll.\(index).viewport"] = Rect(bounds)
        let horizontal = scroll.axis == "x"
        if scroll.scope == "database", horizontal,
           scroll.anchor?.blockClass == "notion-timeline-item-properties" {
            try await activateTimelineToday(in: source)
            try await wait {
                guard let frame = try? self.scrollFrame(scroll, source: source) else { return false }
                return frame.width > 0 && frame.height > 0
            }
            (viewport, bounds) = try scopedViewport(scroll.scope, container: scroll.container, axis: scroll.axis)
            result.observedGeometry["scroll.\(index).viewport"] = Rect(bounds)
        }
        if scroll.scope == "code", scroll.mode != "anchor" {
            try ax.set(web,"AXFocused",kCFBooleanTrue)
            let delta = Int(bounds.width.rounded()) * (scroll.mode == "start" ? 1 : -1)
            var previous = "", stable = 0
            while stable < 3 {
                try ax.wheel(delta,viewport:viewport,horizontal:true); try await pause()
                let current = try await viewportPixels(viewport)
                stable = current == previous ? stable + 1 : 0; previous = current
            }
            let boundary = previous
            var moved = false
            for _ in 0..<4 {
                try ax.wheel(-delta,viewport:viewport,horizontal:true); try await pause()
                if try await viewportPixels(viewport) != boundary { moved = true; break }
            }
            guard moved else { throw ScenarioFailure("unsupported", "No pixel movement in code pane; scroll boundary cannot be proven") }
            while true {
                try ax.wheel(delta,viewport:viewport,horizontal:true); try await pause()
                if try await viewportPixels(viewport) == boundary { break }
            }
            visualBoundaries[index] = boundary
            visualFrames[index] = bounds
            result.environment["scroll.\(index).boundary"] = "\(scroll.mode); selected-window code pixels stable, reverse movement and exact return verified"
            result.environment["scroll.\(index).pixelSHA256"] = boundary
            if let advance = scroll.advancePixels { try await advancePixels(advance,viewport:viewport,horizontal:true,index:index) }
            return
        }
        if scroll.mode == "anchor" {
            if let anchor = scroll.anchor, let element = try ax.unique(anchor, in: source) {
                try? ax.press(element, action: "AXScrollToVisible")
                try await pause()
                if let location = scroll.rangeLocation, let length = scroll.rangeLength {
                    try ax.set(element,"AXFocused",kCFBooleanTrue)
                    var range = CFRange(location:location,length:length)
                    try ax.set(element,"AXSelectedTextRange",AXValueCreate(.cfRange,&range)!)
                    try await pause()
                }
            }
            var fullSize: CGFloat?
            var stable = 0
            while stable < 2 {
                try checkTime()
                (viewport, bounds) = try scopedViewport(scroll.scope, container: scroll.container, axis: scroll.axis)
                guard let frame = try scrollFrame(scroll, source: source), frame.width > 0, frame.height > 0 else {
                    throw ScenarioFailure("anchor_missing", "Scoped scroll anchor is not visible")
                }
                result.observedGeometry["scroll.\(index).lastAnchorAttempt"] = Rect(frame)
                let low = horizontal ? frame.minX : frame.minY
                let high = horizontal ? frame.maxX : frame.maxY
                let start = horizontal ? bounds.minX : bounds.minY
                let end = horizontal ? bounds.maxX : bounds.maxY
                if fullSize == nil && (scroll.offset ?? 0) < 0 {
                    if low <= start + 2 || high >= end - 2 {
                        try ax.wheel(-Int((low - (start + end) / 2).rounded()), viewport: viewport, horizontal: horizontal)
                        try await pause(); continue
                    }
                    fullSize = horizontal ? frame.width : frame.height
                    scrollFullSizes[index] = fullSize
                    result.observedGeometry["scroll.\(index).anchorBeforeClipping"] = Rect(frame)
                }
                let origin = (scroll.offset ?? 0) < 0 ? high - (fullSize ?? 0) : low
                let error = origin - start - (scroll.offset ?? 0)
                if abs(error) <= 2 { stable += 1 }
                else { stable = 0; try ax.wheel(-Int(error.rounded()), viewport: viewport, horizontal: horizontal) }
                try await pause()
            }
            guard let frame = try scrollFrame(scroll, source: source) else { throw ScenarioFailure("anchor_missing", "Scroll anchor disappeared") }
            scrollObservations[index] = frame
            result.observedGeometry["scroll.\(index).viewport"] = Rect(bounds)
            result.observedGeometry["scroll.\(index).anchor"] = Rect(frame)
            if let advance = scroll.advancePixels { try await advancePixels(advance,viewport:viewport,horizontal:horizontal,index:index) }
        } else {
            // A boundary must be witnessed by stable content geometry, with a reverse/return probe.
            struct Witness: Equatable { let text: String; let rect: Rect }
            func signature() -> [Witness] {
                let observed = ax.nodes(viewport)
                func witnesses(roles: [String], confinedToViewport: Bool) -> [Witness] {
                    observed.filter {
                        roles.contains(ax.text($0, "AXRole")) &&
                        !ax.classes($0).contains("whenContentEditable")
                    }.compactMap { node -> Witness? in
                        guard let frame = ax.frame(node), frame.width > 2, frame.height > 2 else { return nil }
                        let text = ax.label(node)
                        if confinedToViewport && (text.isEmpty || !frame.intersects(bounds)) { return nil }
                        return Witness(text: text, rect: Rect(frame))
                    }.prefix(30).map { $0 }
                }
                let text = witnesses(roles: ["AXTextArea", "AXStaticText", "AXCell", "AXLink"],
                                     confinedToViewport: false)
                if !text.isEmpty { return text }
                // Some DB views expose their content solely as titled controls.
                return witnesses(roles: ["AXButton", "AXPopUpButton", "AXRadioButton"],
                                 confinedToViewport: true)
            }
            let delta = Int((horizontal ? bounds.width : bounds.height).rounded()) * (scroll.mode == "start" ? 1 : -1)
            var previous: [Witness] = [], stable = 0
            while stable < 3 {
                try checkTime()
                try ax.wheel(delta, viewport: viewport, horizontal: horizontal); try await pause()
                let current = signature()
                if current.isEmpty { stable = 0; previous = []; continue }
                stable = current == previous ? stable + 1 : 0; previous = current
            }
            let boundary = previous
            result.environment["scroll.\(index).phase"] = "reverse-probe"
            var moved = false
            for _ in 0..<4 {
                try checkTime()
                try ax.wheel(-delta, viewport: viewport, horizontal: horizontal); try await pause()
                if signature() != boundary { moved = true; break }
            }
            guard moved else { throw ScenarioFailure("unsupported", "No observed movement in this scroll container; boundary cannot be proven") }
            result.environment["scroll.\(index).phase"] = "return-probe"
            try ax.wheel(delta, viewport: viewport, horizontal: horizontal)
            try await wait {
                if signature() == boundary { return true }
                try self.ax.wheel(delta, viewport: viewport, horizontal: horizontal)
                return false
            }
            result.environment["scroll.\(index).boundary"] = "\(scroll.mode); reverse and return movement verified"
            if let witness = boundary.first,
               let node = ax.nodes(viewport).first(where: { ax.label($0) == witness.text && ax.frame($0).map({ Rect($0) == witness.rect }) == true }) {
                scrollObservations[index] = witness.rect.cgRect
                boundaryElements[index] = (node, witness.rect.cgRect)
                boundaryLabels[index] = witness.text
                result.environment["scroll.\(index).boundaryWitness"] = witness.text
            } else { throw ScenarioFailure("unsupported", "No persistent content witness for final boundary readback") }
        }
    }
    private func activateTimelineToday(in source: AXUIElement) async throws {
        guard !timelineTodayApplied else { return }
        guard let today = ax.nodes(source).first(where: {
            ax.text($0, "AXRole") == "AXButton" && ax.label($0) == "Today" &&
            (ax.frame($0).map { $0.width > 2 && $0.height > 2 } ?? false)
        }) else { throw ScenarioFailure("unsupported", "Timeline Today control is unavailable") }
        try ax.click(today)
        timelineTodayApplied = true
        result.environment["timelineNavigation"] = "Today control used to reveal fixture dated items before positioning the timeline anchor"
        try await pause()
    }
    func applyScopedScrolls() async {
        var observed: [ViewportScrollRequest] = []
        for (index, scroll) in (request.scenario.state.scrolls ?? []).enumerated() {
            if !result.steps.contains(where: { $0.item == "scroll.\(index)" && $0.status == "verified" }) {
                await step("scroll.\(index)") { try await self.scopedScroll(scroll, index: index) }
            }
            if result.steps.contains(where: { $0.item == "scroll.\(index)" && $0.status == "verified" }) { observed.append(scroll) }
        }
        result.observed.scrolls = observed
    }
    func requestedRegion() throws -> CGRect {
        guard let windowFrame = ax.frame(window), let region = request.scenario.state.captureRegion else {
            throw ScenarioFailure("invalid_region", "Region or window geometry missing")
        }
        if let rect = region.rect { return rect.cgRect }
        let scope = region.scope ?? "main"
        let source = try root(scope)
        let (_, viewport) = try scopedViewport(scope)
        var rect = viewport
        if let anchor = region.anchor {
            guard let element = try ax.unique(anchor, in: source) else { throw ScenarioFailure("anchor_missing", "Crop anchor is not loaded") }
            var target = element
            if region.target == "followingImage" {
                let nodes = ax.nodes(source)
                guard let index = nodes.firstIndex(where: { CFEqual($0, element) }),
                      let block = nodes.dropFirst(index + 1).first(where: { ax.classes($0).contains("notion-image-block") }) else {
                    throw ScenarioFailure("unsupported", "The image following the crop anchor is not exposed by AX")
                }
                let bitmap = ax.nodes(block).first(where: { ax.text($0, "AXRole") == "AXImage" && (ax.frame($0).map { $0.width > 50 && $0.height > 50 } ?? false) })
                target = bitmap ?? block
                result.environment["imageCropExtent"] = bitmap == nil ? "AX image block (bitmap AXImage is not exposed); inspect PNG to verify the cut" : "AXImage"
            }
            guard let frame = ax.frame(target), frame.width > 0, frame.height > 0 else {
                throw ScenarioFailure("anchor_missing", "Crop anchor is not visible")
            }
            let fraction = region.fraction ?? 0.5
            switch region.cutEdge {
            case "left": rect.origin.x = frame.minX + frame.width * fraction; rect.size.width = viewport.maxX - rect.minX
            case "right": rect.size.width = frame.minX + frame.width * fraction - rect.minX
            case "top": rect.origin.y = frame.minY + frame.height * fraction; rect.size.height = viewport.maxY - rect.minY
            case "bottom": rect.size.height = frame.minY + frame.height * fraction - rect.minY
            default: throw ScenarioFailure("invalid_region", "Unknown crop edge")
            }
        }
        rect = rect.intersection(windowFrame)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { throw ScenarioFailure("invalid_region", "Crop does not intersect target window") }
        return rect.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
    }
    func applyOverlay(_ overlay: OverlayRequest) async throws {
        let element: AXUIElement
        if let targetClass = overlay.targetClass {
            guard targetClass.hasPrefix("notion-") else { throw ScenarioFailure("unsupported", "Overlay targets require semantic Notion classes") }
            let hits=ax.nodes(web).filter { ax.classes($0).contains(targetClass) && (ax.frame($0).map { $0.width>1 && $0.height>1 } ?? false) }
            guard hits.count == 1 else { throw ScenarioFailure("unsupported", "Overlay semantic target is ambiguous") }
            element=hits[0]
        } else if overlay.kind == "hover" {
            let hits=ax.nodes(web).filter { ["AXLink","AXButton","AXPopUpButton"].contains(ax.text($0,"AXRole")) && ax.label($0)==overlay.text && (ax.frame($0).map { $0.width>1 && $0.height>1 } ?? false) }
            guard hits.count == 1 else { throw ScenarioFailure("unsupported", "Hover target is ambiguous") }
            element=hits[0]
        } else { element = try control(overlay.text, in:web) }
        if overlay.kind == "menu" || overlay.kind == "popup" {
            try activate(element)
            var opened = false
            for _ in 0..<8 {
                if overlayVisible(overlay) { opened = true; break }
                try await pause()
            }
            if !opened { try ax.click(element) }
        }
        else {
            guard var frame = ax.frame(element) else { throw ScenarioFailure("unsupported", "Tooltip target has no frame") }
            if overlay.targetClass != nil {
                let children=ax.children(element).compactMap { ax.frame($0) }.filter { $0.width>1 && $0.height>1 && frame.contains($0) }
                // Semantic hover roots may include empty space around a single
                // trigger group. Use that group's center, not viewport center.
                if children.count == 1 { frame=children[0] }
            }
            if let page = ax.frame(web) { ax.move(CGPoint(x:page.midX,y:page.minY+60)); try await pause() }
            ax.move(CGPoint(x: frame.midX, y: frame.midY))
        }
        if ["tooltip","hover","popup"].contains(overlay.kind), let expected = overlay.expectedText {
            while true {
                try await pause()
                let (image,_) = try await windowImage()
                if try imageContains(image,text:expected,substring:["hover","popup"].contains(overlay.kind)) { break }
            }
            result.environment["overlayVerification"] = "Vision OCR of selected-window pixels; final proof uses screen.png"
        } else { try await wait { self.overlayVisible(overlay) } }
        result.observed.overlay = overlay
    }
    func overlayVisible(_ overlay: OverlayRequest) -> Bool {
        ax.nodes(web).contains { node in
            (overlay.kind == "popup" && ax.text(node,"AXSubrole") == "AXApplicationDialog") ||
            ax.text(node,"AXRole") == (overlay.kind == "menu" ? "AXMenu" : "AXHelpTag") ||
            (overlay.kind == "menu" && overlay.text == "Actions" &&
             ["AXComboBox", "AXTextField", "AXSearchField"].contains(ax.text(node,"AXRole")) &&
             ax.text(node,"AXPlaceholderValue").replacingOccurrences(of: "...", with: "…") == "Search actions…")
        }
    }
    func imageContains(_ image: CGImage, text: String, substring: Bool = false) throws -> Bool {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = substring ? ["ja-JP","en-US"] : ["en-US"]
        try VNImageRequestHandler(cgImage:image).perform([request])
        func normalized(_ value:String) -> String { value.split(whereSeparator: { $0.isWhitespace }).joined(separator:" ") }
        func compact(_ value:String)->String { value.folding(options:.widthInsensitive,locale:nil).filter { !$0.isWhitespace } }
        return (request.results ?? []).contains {
            let actual=$0.topCandidates(1).first?.string ?? ""
            return substring ? compact(actual).contains(compact(text)) : normalized(actual) == normalized(text)
        }
    }
    func viewportPixels(_ viewport: AXUIElement) async throws -> String {
        guard let frame = ax.frame(viewport) else { throw ScenarioFailure("capture_failed", "Code viewport disappeared") }
        return try await framePixels(frame)
    }
    func advancePixels(_ distance: Int, viewport: AXUIElement, horizontal: Bool, index: Int) async throws {
        try ax.set(web,"AXFocused",kCFBooleanTrue)
        guard let frame = ax.frame(viewport) else { throw ScenarioFailure("unsupported", "Advance viewport disappeared") }
        parkPointer(); try await pause()
        let before = try await framePixels(frame)
        try ax.wheel(-distance,viewport:viewport,horizontal:horizontal)
        parkPointer()
        var previous = "", stable = 0
        while stable < 2 {
            try await pause()
            let current = try await framePixels(frame)
            stable = current == previous ? stable+1 : 0; previous = current
        }
        guard previous != before else { throw ScenarioFailure("unsupported", "Pixel advance produced no visible content movement") }
        visualFrames[index] = frame; visualBoundaries[index] = previous
        result.environment["scroll.\(index).advancePixels"] = "\(distance) CGEvent pixel units after verified reference; movement and stable pixels observed"
        result.environment["scroll.\(index).pixelSHA256"] = previous
    }
    func parkPointer() {
        if let frame = ax.frame(window) { ax.move(CGPoint(x:frame.midX,y:frame.minY-4)) }
    }
    func framePixels(_ frame: CGRect, captured: Bool = false) async throws -> String {
        let image: CGImage, windowFrame: CGRect
        if captured {
            guard let info = result.screenshot,
                  let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(info.file) as CFURL,nil),
                  let saved = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw ScenarioFailure("capture_failed", "Final pixel proof has no saved screenshot") }
            image = saved; windowFrame = info.frame.cgRect
        } else { (image,windowFrame) = try await windowImage() }
        guard let pixels = RegionGeometry.pixels(region:frame.insetBy(dx:2,dy:2).offsetBy(dx:-windowFrame.minX,dy:-windowFrame.minY),window:windowFrame,pixelWidth:image.width,pixelHeight:image.height),
              let crop = image.cropping(to:pixels),
              let context = CGContext(data:nil,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScenarioFailure("capture_failed", "Cannot read selected-window pixels for code scroll verification")
        }
        context.draw(crop,in:CGRect(x:0,y:0,width:crop.width,height:crop.height))
        guard let bytes = context.data else { throw ScenarioFailure("capture_failed", "Cannot read code pixel buffer") }
        return SHA256.hash(data:Data(bytes:bytes,count:crop.width*crop.height*4)).map { String(format:"%02x",$0) }.joined()
    }
    func verifyScreenState(includeOverlay: Bool = true) async throws {
        let state = request.scenario.state
        if let p = state.presentation {
            if p.mode == "none" { guard peekRoot() == nil else { throw ScenarioFailure("state_drift", "A preview appeared") } }
            else if p.mode == "full" {
                guard let id = request.previewPageId, ax.isPage(web, pageId: id) else { throw ScenarioFailure("state_drift", "Full page target changed") }
            } else {
                guard let identity = previewIdentity(), identity.id == request.previewPageId, identity.mode == p.mode else { throw ScenarioFailure("state_drift", "Preview identity or mode changed") }
                if let fraction = p.widthFraction, let frame = peekRoot().flatMap({ ax.frame($0) }), let page = ax.frame(web), abs(frame.width - page.width * fraction) > 2 {
                    throw ScenarioFailure("state_drift", "Preview width changed")
                }
            }
        }
        if let side = state.sidebar {
            guard sidebar()?.0 == (side.mode == "pinned") else { throw ScenarioFailure("state_drift", "Sidebar mode changed") }
            if side.mode == "floating", (try? root("sidebar")) == nil { throw ScenarioFailure("state_drift", "Floating sidebar disappeared") }
            if side.mode == "closed", (try? root("sidebar")) != nil { throw ScenarioFailure("state_drift", "A floating sidebar appeared") }
            if let width = side.width, let frame = try ax.frame(root("sidebar")), abs(frame.width - width) > 2 { throw ScenarioFailure("state_drift", "Sidebar width changed") }
        }
        for (index, scroll) in (state.scrolls ?? []).enumerated() {
            guard result.steps.contains(where: { $0.item == "scroll.\(index)" && $0.status == "verified" }) else { throw ScenarioFailure("prerequisite_failed", "A scoped scroll was not verified") }
            if state.presentation?.mode == "center", scroll.scope == "main" {
                guard result.steps.contains(where: { $0.item == "backgroundState" && $0.status == "verified" }) else { throw ScenarioFailure("prerequisite_failed", "Center peek background was not verified") }
                result.environment["backgroundReadback"] = "Background scroll verified before center peek; modal background AX nodes are not claimed visible in final state."
                continue
            }
            if let expected = visualBoundaries[index] {
                guard let frame = visualFrames[index], try await framePixels(frame,captured:true) == expected else { throw ScenarioFailure("state_drift", "Captured pane pixels differ from the verified scroll operation") }
                continue
            }
            if scroll.mode == "anchor" {
                let source = try root(scroll.scope)
                let (_, viewport) = try scopedViewport(scroll.scope, container: scroll.container, axis: scroll.axis)
                guard let frame = try scrollFrame(scroll, source: source), scrollObservations[index] != nil else {
                    throw ScenarioFailure("state_drift", "Scoped scroll anchor disappeared")
                }
                let origin = (scroll.offset ?? 0) < 0
                    ? (scroll.axis == "x" ? frame.maxX : frame.maxY) - (scrollFullSizes[index] ?? 0)
                    : (scroll.axis == "x" ? frame.minX : frame.minY)
                let actualOffset = origin - (scroll.axis == "x" ? viewport.minX : viewport.minY)
                guard abs(actualOffset - (scroll.offset ?? 0)) <= 2 else {
                    throw ScenarioFailure("state_drift", "Scoped scroll \(index) moved after later actions (offset=\(Int(actualOffset.rounded())), expected=\(Int((scroll.offset ?? 0).rounded())))")
                }
            } else {
                guard let (node, before) = boundaryElements[index] else {
                    throw ScenarioFailure("state_drift", "Scroll boundary witness disappeared")
                }
                let replacement = boundaryLabels[index].flatMap { try? ax.unique(Anchor(text:$0),in:root(scroll.scope)) }
                guard let after = replacement.flatMap({ ax.frame($0) }) ?? ax.frame(node) else { throw ScenarioFailure("state_drift", "Scroll boundary witness disappeared") }
                let horizontal = scroll.axis == "x"
                let delta = horizontal ? abs(after.minX-before.minX) + abs(after.width-before.width)
                                       : abs(after.minY-before.minY) + abs(after.height-before.height)
                guard delta <= 2, (horizontal ? after.width : after.height) > 0 else {
                    throw ScenarioFailure("state_drift", "Scroll moved from its observed boundary")
                }
            }
        }
        if let name = state.databaseView, currentDatabaseView() != name { throw ScenarioFailure("state_drift", "Database view changed") }
        for tab in state.tabs ?? [] {
            guard let node = try ax.unique(tab.contentAnchor, in: root(tab.scope)), ax.frame(node).map({ $0.width > 0 && $0.height > 0 }) == true else { throw ScenarioFailure("state_drift", "Selected tab content disappeared") }
        }
        for display in state.blockDisplays ?? [] {
            let block = try displayBlock(display, in: root(display.scope))
            guard blockDisplayMatches(display, in: block) else { throw ScenarioFailure("state_drift", "Diagram display mode changed") }
        }
        if includeOverlay, let overlay = state.overlay {
            if ["tooltip","hover","popup"].contains(overlay.kind), let text = overlay.expectedText {
                guard let source = CGImageSourceCreateWithURL(directory.appendingPathComponent("screen.png") as CFURL,nil),
                      let image = CGImageSourceCreateImageAtIndex(source,0,nil), try imageContains(image,text:text,substring:["hover","popup"].contains(overlay.kind)) else {
                    throw ScenarioFailure("state_drift", "Requested tooltip text is absent from the captured window pixels")
                }
            } else if !overlayVisible(overlay) {
                throw ScenarioFailure("state_drift", "Requested overlay disappeared")
            }
        }
        if let frame = regionFrame, !Rect(frame).near(Rect(try requestedRegion())) { throw ScenarioFailure("state_drift", "Capture region geometry changed") }
    }

    func captureSupplementalState() async {
        for tab in request.captureTabs ?? [] {
            guard let source = try? root(tab.scope), let control = try? tabControl(tab.selectedText, in: source), selected(control) == true,
                  let content = try? ax.unique(tab.contentAnchor, in: source), ax.frame(content).map({ $0.width > 0 && $0.height > 0 }) == true else { continue }
            result.observed.tabs = (result.observed.tabs ?? []) + [tab]
        }
        if !(request.captureBlockDisplays ?? []).isEmpty {
            result.environment["capture.blockDisplays"] = "not persisted: Mermaid display mode replay can alter modification timestamps"
        }
        if let mode = sidebar()?.0 {
            if let source = try? root("sidebar"), let frame = ax.frame(source) {
                result.observed.sidebar = SidebarRequest(mode: mode ? "pinned" : "floating", width: frame.width)
                result.observed.sidebarOpen = nil
                result.observedGeometry["sidebar"] = Rect(frame)
            }
        }
        guard let views = request.databaseViewNames, !views.isEmpty else { return }
        await step("databaseView") {
            guard let name = self.currentDatabaseView(), views.contains(name) else { throw ScenarioFailure("unsupported", "Cannot capture the current database view") }
            self.result.observed.databaseView = name
        }
        await step("scroll.database") {
            let source = self.mainRoot()
            let (_, viewport) = try self.scopedViewport("database")
            let references = (self.request.pageReferences ?? []).filter { $0.fixtureId == self.request.scenario.fixtureId && $0.rowIndex != nil }
            var rowAnchor: Anchor?
            for reference in references {
                let anchor = Anchor(text: reference.title)
                guard let node = try? self.ax.unique(anchor, in: source), let frame = self.ax.frame(node),
                      frame.height > 0, frame.minY > viewport.minY + 2, frame.maxY < viewport.maxY - 2 else { continue }
                rowAnchor = anchor
                self.result.observed.scrolls = (self.result.observed.scrolls ?? []) + [ViewportScrollRequest(scope: "database", axis: "y", mode: "anchor", anchor: anchor, offset: frame.minY - viewport.minY)]
                break
            }
            guard rowAnchor != nil else { throw ScenarioFailure("unsupported", "No unique visible record anchor to capture database vertical position") }
            let (_, horizontal) = try self.scopedViewport("database", axis: "x")
            var candidates = (self.request.databasePropertyNames ?? []).map { Anchor(text: $0) }
            if let rowAnchor { candidates.append(rowAnchor) }
            for anchor in candidates {
                guard let node = try? self.ax.unique(anchor, in: source), let frame = self.ax.frame(node), frame.height > 0,
                      frame.width > 0, frame.minX > horizontal.minX + 2, frame.maxX < horizontal.maxX - 2 else { continue }
                self.result.observed.scrolls = (self.result.observed.scrolls ?? []) + [ViewportScrollRequest(scope: "database", axis: "x", mode: "anchor", anchor: anchor, offset: frame.minX - horizontal.minX)]
                return
            }
            throw ScenarioFailure("unsupported", "No unique visible database column anchor to capture horizontal position")
        }
    }

    func capturePresentation() async {
        await step("presentation") {
            guard let identity = self.previewIdentity() else {
                guard self.peekRoot() == nil else { throw ScenarioFailure("unsupported", "Open preview identity cannot be read") }
                let records = (self.request.pageReferences ?? []).filter { $0.pageId == self.request.pageId && $0.rowIndex != nil }
                if records.count == 1, let record = records.first {
                    self.result.observed.presentation = PresentationRequest(mode: "full", fixtureId: record.fixtureId, rowIndex: record.rowIndex)
                } else {
                    self.result.observed.presentation = PresentationRequest(mode: "none")
                }
                return
            }
            let references = (self.request.pageReferences ?? []).filter { $0.pageId == identity.id }
            guard references.count == 1, let ref = references.first, identity.mode != "unknown" else {
                throw ScenarioFailure("unsupported", "Open preview is not one uniquely registered Fixture page")
            }
            var fraction: Double?
            if identity.mode == "side", let frame = self.peekRoot().flatMap({ self.ax.frame($0) }), let page = self.ax.frame(self.web) {
                fraction = frame.width / page.width
            }
            self.result.observed.presentation = PresentationRequest(mode: identity.mode, fixtureId: ref.fixtureId, rowIndex: ref.rowIndex, widthFraction: fraction)
            self.result.environment["previewPageId"] = identity.id
        }
        if ["side", "center"].contains(result.observed.presentation?.mode ?? "") {
            await step("scroll.preview") {
                let source = try self.root("preview")
                let (_, viewport) = try self.scopedViewport("preview")
                let candidates = self.ax.leaves(source).filter { leaf in
                    guard let frame = self.ax.frame(leaf) else { return false }
                    return frame.width > 0 && frame.minY > viewport.minY + 2 && frame.maxY < viewport.maxY - 2 && frame.height > 0
                }
                guard let leaf = candidates.first else { throw ScenarioFailure("unsupported", "No fully visible preview text anchor") }
                let anchor = Anchor(text: self.ax.text(leaf, "AXValue"))
                guard self.ax.matching(anchor, in: source).count == 1, let frame = self.ax.frame(leaf) else { throw ScenarioFailure("ambiguous_anchor", "Preview anchor is ambiguous") }
                self.result.observed.scrolls = [ViewportScrollRequest(scope: "preview", axis: "y", mode: "anchor", anchor: anchor, offset: frame.minY - viewport.minY)]
            }
        }
    }
}
