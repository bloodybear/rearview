import Foundation
import Testing
@testable import Rearview

@Suite
struct PipelinePolicyTests {
    @Test func latestValueLatchKeepsOnlyNewestReadyValue() {
        var latch = LatestValueLatch<Int>()
        latch.store(1)
        latch.store(2)
        #expect(latch.take(when: false) == nil)
        #expect(latch.value == 2)
        #expect(latch.take(when: true) == 2)
        #expect(latch.value == nil)
        latch.store(3)
        latch.clear()
        #expect(latch.value == nil)
    }

    @Test func selectionTargetPreviewAcceptsResultsNewerThanLastDisplayedRequest() {
        #expect(shouldDisplaySelectionTargetPreview(
            requestID: 11, lastDisplayedRequestID: 10
        ))
        #expect(!shouldDisplaySelectionTargetPreview(
            requestID: 10, lastDisplayedRequestID: 10
        ))
        #expect(!shouldDisplaySelectionTargetPreview(
            requestID: 9, lastDisplayedRequestID: 10
        ))
    }

    @Test func frameMotionClassifiesScrollLocalChangeSceneChangeAndStableFrames() {
        let columns = 16
        let rows = 12
        let source = testMotionSource(columns: columns, rows: rows)
        var scrolled = [UInt8](repeating: 0, count: source.count)
        for row in 1..<rows {
            for column in 0..<columns {
                scrolled[row * columns + column] = source[(row - 1) * columns + column]
            }
        }
        let scroll = classifyFrameMotion(
            previous: source, current: scrolled, columns: columns, rows: rows
        )
        #expect(scroll.kind == .scroll)
        #expect(scroll.shift == FrameShift(x: 0, y: 1))
        var local = source
        local[5] &+= 40
        #expect(classifyFrameMotion(
            previous: source, current: local, columns: columns, rows: rows
        ).kind == .localOrScroll)
        let scene = source.map { 255 &- $0 }
        #expect(classifyFrameMotion(
            previous: source, current: scene, columns: columns, rows: rows
        ).kind == .sceneChange)
        #expect(classifyFrameMotion(
            previous: source, current: source, columns: columns, rows: rows
        ).kind == .unchanged)
        #expect(classifyFrameMotion(
            previous: [], current: [], columns: columns, rows: rows
        ).kind == .sceneChange)
    }

    @Test @MainActor func translationCommitRequiresCurrentGenerationAndNotCancellation() {
        #expect(TranslationBroker.canCommitResults(
            activeGeneration: 3, currentGeneration: 3, isCancelled: false
        ))
        #expect(!TranslationBroker.canCommitResults(
            activeGeneration: 3, currentGeneration: 4, isCancelled: false
        ))
        #expect(!TranslationBroker.canCommitResults(
            activeGeneration: 3, currentGeneration: 3, isCancelled: true
        ))
    }

    @Test func translationPlansPreserveNonSourceSegmentsAndRebuildExactly() {
        let source = "Start ボタン을 2回押す"
        let plan = LanguageProtector.makeTranslationPlan(for: source)
        #expect(plan.segments.map(\.text).joined() == source)
        let preserved = plan.segments.filter { $0.kind == .preserve }.map(\.text).joined()
        #expect(preserved.contains("Start"))
        #expect(preserved.contains("을"))
        #expect(preserved.contains("2"))
        #expect(plan.segments.filter { $0.kind == .translate }.allSatisfy {
            !$0.text.contains("Start") && !$0.text.contains("을") && !$0.text.contains("2")
        })

        let KoreanPlan = LanguageProtector.makeTranslationPlan(
            for: "한국어 Start 2", direction: .koreanToJapanese
        )
        #expect(KoreanPlan.segments.first?.kind == .translate)
        #expect(KoreanPlan.segments.filter { $0.kind == .translate }
            .map(\.text).joined().contains("한국어"))
        #expect(!LanguageProtector.containsSourceLanguage("日本語", direction: .koreanToJapanese))
        #expect(LanguageProtector.containsSourceLanguage("한국어", direction: .koreanToJapanese))

        let cases = [
            "Save 設定을 2回変更", "HTTP APIを呼び出す", "한국어 のまま表示",
            "Version 3.1 を選択", "開始 버튼 Click"
        ]
        for mixed in cases {
            let mixedPlan = LanguageProtector.makeTranslationPlan(for: mixed)
            #expect(mixedPlan.segments.map(\.text).joined() == mixed)
            for segment in mixedPlan.segments where segment.kind == .translate {
                #expect(!segment.text.unicodeScalars.contains { scalar in
                    (0xAC00...0xD7AF).contains(scalar.value)
                        || (0x0041...0x005A).contains(scalar.value)
                        || (0x0061...0x007A).contains(scalar.value)
                        || CharacterSet.decimalDigits.contains(scalar)
                })
            }
        }
    }

    @Test func captureTargetResolutionUsesVisibleWindowCoverage() {
        let appA = CaptureApplication(
            processID: 10, bundleIdentifier: "test.a", name: "A",
            anchorWindowID: 100, anchorWindowFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let appB = CaptureApplication(
            processID: 20, bundleIdentifier: "test.b", name: "B",
            anchorWindowID: 200, anchorWindowFrame: CGRect(x: 50, y: 0, width: 100, height: 100)
        )
        let selection = CGRect(x: 0, y: 0, width: 100, height: 100)
        let single = resolveCaptureTarget(
            windows: [(appA, appA.anchorWindowFrame!)], intersecting: selection
        )
        #expect(single.target == .application(appA))
        #expect(single.candidate == appA)
        let partial = resolveCaptureTarget(
            windows: [
                (appA, CGRect(x: 0, y: 0, width: 75, height: 100)),
                (appB, appB.anchorWindowFrame!)
            ], intersecting: selection
        )
        #expect(partial.target == .allContent)
        #expect(partial.candidate == appA)
        let covered = resolveCaptureTarget(windows: [
            (appA, appA.anchorWindowFrame!),
            (appB, CGRect(x: 20, y: 20, width: 20, height: 20))
        ], intersecting: selection)
        #expect(covered.target == .application(appA))
        let sameAppSecondWindow = CaptureApplication(
            processID: 10, bundleIdentifier: "test.a", name: "A",
            anchorWindowID: 101, anchorWindowFrame: CGRect(x: 80, y: 0, width: 20, height: 100)
        )
        #expect(resolveCaptureTarget(windows: [
            (appA, CGRect(x: 0, y: 0, width: 80, height: 100)),
            (sameAppSecondWindow, sameAppSecondWindow.anchorWindowFrame!)
        ], intersecting: selection).target == .allContent)
        #expect(resolveCaptureTarget(windows: [], intersecting: selection)
            == CaptureTargetResolution(target: .allContent, candidate: nil))
    }

    @Test func selectionBadgesAvoidUpperLeftCollision() {
        let selection = CGRect(x: 100, y: 100, width: 500, height: 300)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let target = SelectionBadgePlacement.targetFrame(
            for: selection, size: CGSize(width: 150, height: 36), in: bounds
        )
        let pixel = SelectionBadgePlacement.pixelFrame(
            for: selection, size: CGSize(width: 92, height: 32),
            cursor: CGPoint(x: 110, y: 390), in: bounds, avoiding: target
        )

        #expect(target == CGRect(x: 108, y: 356, width: 150, height: 36))
        #expect(pixel != nil)
        #expect(!pixel!.intersects(target!))
        #expect(pixel!.maxY <= target!.minY)
        #expect(pixel!.minX == target!.minX)
    }

    @Test func selectionBadgesRemainVisibleForSmallSelectionAndScreenEdges() {
        let selection = CGRect(x: 4, y: 4, width: 80, height: 40)
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 160)
        let target = SelectionBadgePlacement.targetFrame(
            for: selection, size: CGSize(width: 140, height: 32), in: bounds
        )
        let pixel = SelectionBadgePlacement.pixelFrame(
            for: selection, size: CGSize(width: 92, height: 32),
            cursor: CGPoint(x: 8, y: 36), in: bounds, avoiding: target
        )

        #expect(target != nil)
        #expect(pixel != nil)
        #expect(bounds.contains(target!))
        #expect(bounds.contains(pixel!))
        #expect(!pixel!.intersects(target!))
    }

    @Test func screenAndWindowCoordinatesUseQuartzYConversionAndMinimumSize() {
        let screenFrame = CGRect(x: 100, y: 200, width: 800, height: 600)
        let displayBounds = CGRect(x: 1440, y: 0, width: 800, height: 600)
        let selection = CGRect(x: 120, y: 250, width: 200, height: 100)
        let capture = screenCaptureRect(
            for: selection, screenFrame: screenFrame, displayBounds: displayBounds
        )
        #expect(capture == CGRect(x: 1460, y: 450, width: 200, height: 100))
        #expect(appKitSelectionRect(
            for: capture, screenFrame: screenFrame, displayBounds: displayBounds
        ) == selection)
        let relative = relativeSelectionInWindow(
            selection: selection,
            screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            displayBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            windowFrame: CGRect(x: 100, y: 200, width: 400, height: 300)
        )
        #expect(relative == CGRect(x: 20, y: 50, width: 200, height: 100))
        let moved = projectTrackedSelection(
            relativeSelection: relative,
            windowFrame: CGRect(x: 1440, y: 100, width: 400, height: 300),
            displays: [
                WindowTrackingDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
                WindowTrackingDisplay(displayID: 2, bounds: CGRect(x: 1440, y: 0, width: 800, height: 600))
            ],
            preferredDisplayID: 1
        )
        #expect(moved?.displayID == 2)
        #expect(moved?.captureRect == CGRect(x: 1460, y: 150, width: 200, height: 100))
        let resized = projectTrackedSelection(
            relativeSelection: CGRect(x: 0, y: 0, width: 200, height: 100),
            windowFrame: CGRect(x: 0, y: 0, width: 300, height: 200),
            displays: [WindowTrackingDisplay(displayID: 3, bounds: CGRect(x: 0, y: 0, width: 100, height: 50))],
            preferredDisplayID: 3
        )
        #expect(resized?.captureRect == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(resized?.wasResized == true)
        #expect(projectTrackedSelection(
            relativeSelection: CGRect(x: 0, y: 0, width: 40, height: 20),
            windowFrame: .zero,
            displays: [WindowTrackingDisplay(displayID: 4, bounds: CGRect(x: 0, y: 0, width: 31, height: 20))]
        ) == nil)
    }
}

@Suite(.serialized)
struct PerformanceProfilerTests {
    @Test func reportCountersStagesAndPrivacyBoundary() throws {
        let profiler = PerformanceProfiler.shared
        profiler.start()
        profiler.increment("frame.received", by: 3)
        profiler.setCounter("capture.filter.application", value: 1)
        profiler.increment("frame.overwritten")
        profiler.recordElapsed(
            .mirrorDraw,
            startedAt: DispatchTime.now().uptimeNanoseconds - 5_000_000,
            frameID: 1
        )
        profiler.recordElapsed(
            .mirrorComposite,
            startedAt: DispatchTime.now().uptimeNanoseconds - 2_000_000,
            frameID: 1
        )
        let report = try #require(profiler.stop())
        #expect(report.metadata.schemaVersion == 13)
        #expect(report.counter("frame.received") == 3)
        #expect(report.counter("capture.filter.application") == 1)
        #expect(report.stages.first(where: { $0.stage == .mirrorDraw })?.count == 1)
        #expect(report.stages.first(where: { $0.stage == .mirrorComposite })?.count == 1)

        let diagnosticText = "PUBLIC BENCHMARK OCR"
        let line = testLine(diagnosticText)
        profiler.start(benchmark: false)
        profiler.recordOCRDiagnostics(
            [line], frameID: 1, mode: .realtime,
            regionOfInterest: nil, purpose: .runtime
        )
        let ordinary = try #require(profiler.stop())
        #expect(ordinary.ocrDiagnostics.isEmpty)
        #expect(!String(decoding: try ProfileReportWriter.jsonData(ordinary), as: UTF8.self)
            .contains(diagnosticText))

        profiler.start(benchmark: true)
        profiler.recordOCRDiagnostics(
            [line], frameID: 2, mode: .refinement,
            regionOfInterest: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            purpose: .initialComparison
        )
        let benchmark = try #require(profiler.stop())
        #expect(benchmark.ocrDiagnostics.first?.text == diagnosticText)
        #expect(benchmark.ocrDiagnostics.first?.scope == .roi)
        let json = try ProfileReportWriter.jsonData(report)
        let csv = ProfileReportWriter.csvText(report)
        #expect(!String(decoding: json, as: UTF8.self).contains(diagnosticText))
        #expect(csv.contains("mirrorDraw"))
        #expect(csv.contains("mirrorComposite"))
    }
}
