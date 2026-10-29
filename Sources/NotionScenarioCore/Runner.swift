import AppKit
import ApplicationServices
@preconcurrency import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

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
    private var progress: ((StepResult) -> Void)?
    public init() {}
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
    private func guardTarget() throws {
        guard ax.isPage(web, pageId: request.pageId), ax.process.isActive,
              let focused = ax.get(ax.app, "AXFocusedWindow"), CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, window) else {
            throw ScenarioFailure("document_mismatch", "Notion target document or foreground application changed")
        }
    }
    private func viewport() throws -> (AXUIElement, CGRect) {
        guard let e = ax.viewport(web), let r = ax.frame(e), r.width > 0, r.height > 0 else {
            throw ScenarioFailure("unsupported", "Notion body viewport is not exposed by public AX")
        }
        return (e, r)
    }
    private func step(_ item: String, _ body: () async throws -> Void) async {
        let start = Date()
        var failure: ScenarioFailure?
        var attempts = 0
        // At most two retries, always re-observing before another action.
        for attempt in 0..<3 {
            attempts = attempt + 1
            stepDeadline = min(deadline, Date().addingTimeInterval(10))
            do { try checkTime(); if item != "target" { try guardTarget() }; try await body(); failure = nil; break }
            catch let error as ScenarioFailure {
                failure = error
                if error.code != "timeout" || attempt == 2 || Date() >= deadline { break }
            } catch { failure = ScenarioFailure("operation_failed", String(describing: error)); break }
        }
        var record = StepResult(item: item, status: failure == nil ? "verified" : (failure!.code == "unsupported" ? "unsupported" : "failed"),
                                code: failure?.code, detail: failure?.description ?? "Observed requested state", durationMs: Int(Date().timeIntervalSince(start) * 1000))
        record.attempts = attempts
        result.steps.append(record); progress?(record)
        try? save()
    }
    private func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
    }
    public func run(_ request: RunRequest, directory: URL, progress: ((StepResult) -> Void)? = nil) async -> RunResult {
        self.request = request; self.directory = directory; self.progress = progress; measuredAnchorHeight = nil; web = nil; window = nil
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
        await step("target") {
            guard request.scenario.schemaVersion == 1, request.scenario.state.coordinateSystem == "screen-top-left-points",
                  UUID(uuidString: request.pageId) != nil, ["apply", "capture"].contains(request.operation) else {
                throw ScenarioFailure("invalid_request", "Unsupported scenario schema, coordinate system, operation, or page ID")
            }
            self.ax = try Accessibility()
            self.result.environment["postEventAccess"] = String(CGPreflightPostEventAccess())
            if request.operation == "apply" && !CGPreflightPostEventAccess() {
                throw ScenarioFailure("accessibility_permission", "macOS denied synthetic UI input; enable Accessibility for the actual runner application")
            }
            self.result.environment["notion"] = Bundle(url: self.ax.process.bundleURL!)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            var targets = self.ax.targets(pageId: request.pageId)
            if targets.isEmpty && request.operation == "apply" {
                let compact = request.pageId.replacingOccurrences(of: "-", with: "")
                NSWorkspace.shared.open(URL(string: "notion://www.notion.so/\(compact)")!)
            }
            try await self.wait {
                targets = self.ax.targets(pageId: request.pageId)
                if targets.count > 1 { throw ScenarioFailure("ambiguous_window", "The page is open in multiple windows; close duplicate windows") }
                return targets.count == 1
            }
            self.window = targets[0].0; let targetWeb = targets[0].1
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
                result.steps[result.steps.count - 1].code = "target_window_missing"
                result.steps[result.steps.count - 1].detail = "No window exposing the requested Notion document URL was found"
            }
            result.status = "failed"; result.finishedAt = now(); try? save(); return result
        }
        if request.operation == "capture" { await captureState() }
        else { await applyState() }
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
                if zoom == 100 { try self.ax.menu("Actual Size") }
                else if zoom == 125 { try self.ax.menu("Actual Size"); try self.ax.menu("Zoom In") }
                throw ScenarioFailure("unsupported", "Requested \(zoom)%; public Notion UI exposes no readable numeric zoom. Commands, if available, are attempts only; actual percentage is unknown.")
            }
        }
        if let open = state.sidebarOpen {
            await step("sidebar") {
                guard let current = self.sidebar() else { throw ScenarioFailure("unsupported", "Readable sidebar button unavailable in this Notion locale") }
                if current.0 != open { self.ax.key(42, flags: .maskCommand) }
                try await self.wait { self.sidebar()?.0 == open }
                self.result.observed.sidebarOpen = self.sidebar()?.0
            }
        }
        for (index, toggle) in (state.toggles ?? []).enumerated() {
            await step("toggle.\(index)") {
                try await self.locate(toggle.anchor)
                let (expanded, button) = try self.toggleState(toggle.anchor)
                if expanded != toggle.expanded { try self.ax.press(button) }
                try await self.wait { try self.toggleState(toggle.anchor).0 == toggle.expanded }
                self.result.observed.toggles = (self.result.observed.toggles ?? []) + [toggle]
            }
        }
        if let scroll = state.scroll { await step("scroll") { try await self.settleLayout(); try await self.scroll(scroll) } }
        if let focus = state.focus { await step("focus") { try await self.focus(focus) } }
    }
    private func settleLayout() async throws {
        var previous: [Rect] = [], stable = 0
        while stable < 2 {
            try checkTime()
            let (_, viewport) = try self.viewport()
            let rects = [Rect(viewport)] + ax.leaves(web).prefix(4).compactMap { ax.frame($0).map(Rect.init) }
            stable = rects == previous ? stable + 1 : 0
            previous = rects
            if stable < 2 { try await pause() }
        }
    }
    private func locate(_ anchor: Anchor) async throws {
        if let e = try ax.unique(anchor, in: web), let r = ax.frame(e), r.height > 0 { return }
        ax.key(3, flags: .maskCommand) // Find, never the document's editable content.
        defer { closeFind() }
        var field: AXUIElement?
        try await wait {
            field = self.ax.nodes(self.window).first {
                ["AXTextField", "AXSearchField"].contains(self.ax.text($0, "AXRole")) &&
                self.ax.text($0, "AXPlaceholderValue").lowercased().contains("find")
            }
            return field != nil
        }
        try ax.set(field!, "AXValue", anchor.text as CFString)
        try await wait { self.ax.text(field!, "AXValue") == anchor.text }
        ax.key(36)
        try await wait {
            guard let e = try self.ax.unique(anchor, in: self.web), let r = self.ax.frame(e) else { return false }
            return r.height > 0
        }
    }
    private func closeFind() {
        let fields = ax.nodes(window).filter { ax.text($0, "AXPlaceholderValue").lowercased().contains("find") }
        for field in fields {
            var parent = ax.parent(field)
            for _ in 0..<4 {
                guard let p = parent else { break }
                if let close = ax.nodes(p).first(where: { ax.text($0, "AXRole") == "AXButton" && ax.text($0, "AXDescription") == "Close" }) {
                    try? ax.press(close); return
                }
                parent = ax.parent(p)
            }
        }
        ax.key(53)
    }
    private func toggleState(_ anchor: Anchor) throws -> (Bool, AXUIElement) {
        guard let leaf = try ax.unique(anchor, in: web) else { throw ScenarioFailure("anchor_missing", "Toggle title is not loaded") }
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
        let titles = ax.nodes(web).filter { node in
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
            if let title = ax.nodes(web).first(where: { ax.text($0, "AXRoleDescription") == "page title" }) {
                try? ax.press(title, action: "AXScrollToVisible")
            }
            var prior: CGRect?, stable = 0
            while stable < 2 {
                try checkTime()
                try wheel(Int(vp.height.rounded()))
                try await pause()
                let title = ax.nodes(web).first { ax.text($0, "AXRoleDescription") == "page title" }
                let frame = title.flatMap { ax.frame($0) }
                stable = try topVisible() && frame == prior ? stable + 1 : 0
                prior = frame
            }
            guard let boundary = prior else { throw ScenarioFailure("unsupported", "No visible page title at scroll boundary") }
            result.observedGeometry["topBoundaryCandidate"] = Rect(boundary)
            try wheel(-Int(vp.height.rounded()))
            try await wait {
                let title = self.ax.nodes(self.web).first { self.ax.text($0, "AXRoleDescription") == "page title" }
                guard let title, let frame = self.ax.frame(title) else { return false }
                self.result.observedGeometry["topMovementProbe"] = Rect(frame)
                return abs(frame.minY - boundary.minY) > 2
            }
            try wheel(Int(vp.height.rounded()))
            try await wait {
                let title = self.ax.nodes(self.web).first { self.ax.text($0, "AXRoleDescription") == "page title" }
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
                guard let e = try ax.unique(anchor, in: web), let frame = ax.frame(e) else { throw ScenarioFailure("anchor_missing", "Anchor disappeared while positioning") }
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
        guard let e = try ax.unique(anchor, in: web), let r = ax.frame(e), r.height > 0 else { throw ScenarioFailure("anchor_missing", "Anchor is not visible") }
        let (_, vp) = try viewport()
        result.observedGeometry["anchor"] = Rect(r)
        result.observedGeometry["viewport"] = Rect(vp)
        if let fullHeight { measuredAnchorHeight = fullHeight }
        let top = (fullHeight ?? measuredAnchorHeight).map { r.maxY - $0 } ?? r.minY
        return ScrollRequest(mode: "anchor", anchor: anchor, offset: top - vp.minY)
    }
    private func focus(_ focus: FocusRequest) async throws {
        ax.key(53)
        if focus.mode == "clear" {
            // Focus the non-editable page WebArea; verify focus AND empty selection.
            if let editor = ax.editor(web) {
                var zero = CFRange(location: 0, length: 0)
                try? ax.set(editor, "AXSelectedTextRange", AXValueCreate(.cfRange, &zero)!)
            }
            try ax.set(web, "AXFocused", kCFBooleanTrue)
            try await wait { try self.focusIsClear() }
            result.observed.focus = focus
        } else if focus.mode == "selection", let anchor = focus.anchor, let location = focus.location, let length = focus.length {
            guard let leaf = try ax.unique(anchor, in: web) else { throw ScenarioFailure("anchor_missing", "Selection anchor must already be loaded; focus cannot change the requested scroll") }
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
        guard let editor = ax.editor(web), let selection = range(editor) else { throw ScenarioFailure("unsupported", "Cannot read document selection range") }
        result.environment["observedSelectionUTF16"] = "location=\(selection.location) length=\(selection.length)"
        return selection.length == 0
    }
    private func captureState() async {
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
            let candidates = self.ax.leaves(self.web).filter {
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
            for leaf in self.ax.leaves(self.web) where self.ax.text(leaf, "AXRoleDescription") == "toggle" {
                guard let frame = self.ax.frame(leaf), frame.height > 0 else { continue }
                let anchor = Anchor(text: self.ax.text(leaf, "AXValue"), blockClass: "notion-toggle-block")
                if let expanded = try? self.toggleState(anchor).0 { toggles.append(ToggleRequest(anchor: anchor, expanded: expanded)) }
            }
            self.result.observed.toggles = toggles
        }
        await step("focus") {
            guard try self.focusIsClear() else { throw ScenarioFailure("unsupported", "Current focus/selection is not a readable clear state; omitted") }
            self.result.observed.focus = FocusRequest(mode: "clear")
        }
    }
    private func verifyFinal() async {
        await step("finalState") {
            let state = self.request.scenario.state
            if let frame = state.window, !(self.ax.frame(self.window).map { frame.near(Rect($0)) } ?? false) { throw ScenarioFailure("state_drift", "Window changed after application") }
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
                    let title = self.ax.nodes(self.web).first { self.ax.text($0, "AXRoleDescription") == "page title" }
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
            if let focus = state.focus {
                if focus.mode == "clear" {
                    self.result.observed.focus = nil
                    try await self.wait { try self.focusIsClear() }
                    self.result.observed.focus = focus
                }
                else if let a = focus.anchor, let e = try self.ax.unique(a, in: self.web), let r = self.range(e) {
                    guard r.location == focus.location && r.length == focus.length else { throw ScenarioFailure("state_drift", "Selection changed") }
                } else { throw ScenarioFailure("unsupported", "Cannot verify final selection") }
            }
        }
    }
    private func screenshot() async throws {
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
        let file = directory.appendingPathComponent("screen.png")
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ScenarioFailure("capture_failed", "Cannot create PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ScenarioFailure("capture_failed", "Cannot save PNG") }
        result.screenshot = CaptureInfo(file: "screen.png", frame: Rect(frame), viewport: try? Rect(viewport().1), pixelWidth: image.width, pixelHeight: image.height,
                                        pixelsPerPointX: Double(image.width) / frame.width, pixelsPerPointY: Double(image.height) / frame.height, capturedAt: now())
        result.environment["capture"] = "ScreenCaptureKit desktopIndependentWindow; excludes other windows and cursor; coordinates screen-top-left-points"
    }
}
