import AppKit
import Darwin
import Foundation
import os

enum ProfileStage: String, Codable, CaseIterable, Sendable {
    case captureConversion
    case ocrRealtime
    case ocrRefinement
    case languageFiltering
    case translationQueue
    case translationModel
    case mirrorUpdate
    case mirrorComposite
    case mirrorDraw
    case endToEnd

    var title: String {
        switch self {
        case .captureConversion: L10n.text("화면 이미지 변환")
        case .ocrRealtime: L10n.text("실시간 OCR")
        case .ocrRefinement: L10n.text("보정 OCR")
        case .languageFiltering: L10n.text("일본어 판별")
        case .translationQueue: L10n.text("번역 큐 대기")
        case .translationModel: L10n.text("번역 모델")
        case .mirrorUpdate: L10n.text("미러 프레임 교체")
        case .mirrorComposite: L10n.text("미러 네이티브 합성")
        case .mirrorDraw: L10n.text("미러 그리기")
        case .endToEnd: L10n.text("화면 변화→표시")
        }
    }
}

struct ProfileSpan: Codable, Sendable {
    let stage: ProfileStage
    let startedNanoseconds: UInt64
    let durationNanoseconds: UInt64
    let frameID: UInt64?
    let itemCount: Int?
    let characterCount: Int?
    let mode: String?
}

struct ProfileCounter: Codable, Sendable {
    let name: String
    let value: Int
}

struct SystemSample: Codable, Sendable {
    let elapsedSeconds: Double
    let cpuPercent: Double
    let residentBytes: UInt64
    let threadCount: Int
    let thermalState: String
}

struct StageSummary: Codable, Sendable {
    let stage: ProfileStage
    let count: Int
    let p50Milliseconds: Double
    let p95Milliseconds: Double
    let maxMilliseconds: Double
    let totalMilliseconds: Double
}

struct ProfileMetadata: Codable, Sendable {
    let schemaVersion: Int
    let translationDirection: String
    let startedAt: Date
    let endedAt: Date
    let durationSeconds: Double
    let operatingSystem: String
    let processorCount: Int
    let physicalMemoryBytes: UInt64
    let selectionWidth: Int?
    let selectionHeight: Int?
    let benchmark: Bool
}

enum OCRDiagnosticPurpose: String, Codable, Sendable {
    case initialComparison
    case runtime
    case confidenceRejected
    case alternativeCandidate
}

enum OCRDiagnosticScope: String, Codable, Sendable {
    case fullFrame
    case roi
}

struct NormalizedRegion: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}

struct OCRDiagnostic: Codable, Sendable {
    let frameID: UInt64
    let purpose: OCRDiagnosticPurpose
    let mode: String
    let scope: OCRDiagnosticScope
    let regionOfInterest: NormalizedRegion?
    let text: String
    let confidence: Float
    let scriptCounts: ScriptCounts
    let containsJapanese: Bool
    let detectionReason: JapaneseDetectionReason
    let japaneseProbability: Double?
}

struct SessionReport: Codable, Sendable {
    let metadata: ProfileMetadata
    let stages: [StageSummary]
    let counters: [ProfileCounter]
    let systemSamples: [SystemSample]
    let spans: [ProfileSpan]
    let ocrDiagnostics: [OCRDiagnostic]
    let recommendations: [String]

    func counter(_ name: String) -> Int {
        counters.first(where: { $0.name == name })?.value ?? 0
    }
}

struct ProfileSpanToken: Sendable {
    fileprivate let stage: ProfileStage
    fileprivate let started: UInt64
    fileprivate let frameID: UInt64?
    fileprivate let itemCount: Int?
    fileprivate let characterCount: Int?
    fileprivate let mode: String?
    fileprivate let enabled: Bool
    fileprivate let signpostID: OSSignpostID
}

final class PerformanceProfiler: @unchecked Sendable {
    static let shared = PerformanceProfiler()
    static let maximumRawSpans = 50_000

    private let lock = NSLock()
    private let signpostLog = OSLog(subsystem: "io.github.bloodybear.rearview", category: "profiling")
    private var active = false
    private var benchmark = false
    private var startedAt = Date()
    private var startedUptime: UInt64 = 0
    private var spans: [ProfileSpan] = []
    private var counters: [String: Int] = [:]
    private var systemSamples: [SystemSample] = []
    private var ocrDiagnostics: [OCRDiagnostic] = []
    private var selectionPixels: (Int, Int)?
    private var samplerTask: Task<Void, Never>?
    private var previousCPUTime: Double = 0
    private var previousSampleUptime: UInt64 = 0
    private var sessionOwnerThread: UInt64?
    private(set) var mostRecentReport: SessionReport?

    private init() {}

    var isActive: Bool {
        lock.withLock { active }
    }

    func start(benchmark: Bool = false) {
        let ownerThread = UInt64(pthread_mach_thread_np(pthread_self()))
        while true {
            let acquired = lock.withLock { () -> Bool in
                if active, sessionOwnerThread != ownerThread {
                    return false
                }
                active = true
                sessionOwnerThread = ownerThread
                self.benchmark = benchmark
                startedAt = Date()
                startedUptime = DispatchTime.now().uptimeNanoseconds
                previousSampleUptime = startedUptime
                previousCPUTime = Self.processCPUTime()
                spans.removeAll(keepingCapacity: true)
                counters.removeAll(keepingCapacity: true)
                systemSamples.removeAll(keepingCapacity: true)
                ocrDiagnostics.removeAll(keepingCapacity: true)
                selectionPixels = nil
                return true
            }
            if acquired { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        samplerTask?.cancel()
        samplerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sampleSystem()
            }
        }
    }

    func setSelection(width: Int, height: Int) {
        lock.withLock { selectionPixels = (width, height) }
    }

    func begin(
        _ stage: ProfileStage, frameID: UInt64? = nil, itemCount: Int? = nil,
        characterCount: Int? = nil, mode: String? = nil
    ) -> ProfileSpanToken {
        let enabled = isActive
        let signpostID = enabled ? OSSignpostID(log: signpostLog) : .invalid
        if enabled {
            os_signpost(.begin, log: signpostLog, name: "PipelineStage", signpostID: signpostID,
                        "%{public}s", stage.rawValue)
        }
        return ProfileSpanToken(
            stage: stage, started: DispatchTime.now().uptimeNanoseconds, frameID: frameID,
            itemCount: itemCount, characterCount: characterCount, mode: mode,
            enabled: enabled, signpostID: signpostID
        )
    }

    func end(_ token: ProfileSpanToken) {
        guard token.enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        os_signpost(.end, log: signpostLog, name: "PipelineStage", signpostID: token.signpostID,
                    "%{public}s", token.stage.rawValue)
        let span = ProfileSpan(
            stage: token.stage, startedNanoseconds: token.started,
            durationNanoseconds: now &- token.started, frameID: token.frameID,
            itemCount: token.itemCount, characterCount: token.characterCount, mode: token.mode
        )
        lock.withLock {
            guard active else { return }
            if spans.count < Self.maximumRawSpans || spans.count.isMultiple(of: 10) {
                spans.append(span)
            }
            counters["span.\(token.stage.rawValue)", default: 0] += 1
        }
    }

    func increment(_ name: String, by amount: Int = 1) {
        guard isActive else { return }
        lock.withLock { counters[name, default: 0] += amount }
    }

    func setCounter(_ name: String, value: Int) {
        guard isActive else { return }
        lock.withLock { counters[name] = value }
    }

    func recordOCRDiagnostics(
        _ lines: [RecognizedLine], frameID: UInt64, mode: OCRMode,
        regionOfInterest: CGRect?, purpose: OCRDiagnosticPurpose
    ) {
        lock.withLock {
            guard active, benchmark else { return }
            for line in lines {
                let detection = LanguageProtector.analyzeJapanese(in: line.sourceText)
                ocrDiagnostics.append(OCRDiagnostic(
                    frameID: frameID, purpose: purpose,
                    mode: mode.rawValue,
                    scope: regionOfInterest == nil ? .fullFrame : .roi,
                    regionOfInterest: regionOfInterest.map(NormalizedRegion.init),
                    text: line.sourceText, confidence: line.confidence,
                    scriptCounts: detection.counts,
                    containsJapanese: detection.containsJapanese,
                    detectionReason: detection.reason,
                    japaneseProbability: detection.japaneseProbability
                ))
            }
        }
    }

    func recordElapsed(
        _ stage: ProfileStage, startedAt: UInt64, frameID: UInt64? = nil,
        itemCount: Int? = nil, characterCount: Int? = nil, mode: String? = nil
    ) {
        guard isActive else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let span = ProfileSpan(
            stage: stage, startedNanoseconds: startedAt,
            durationNanoseconds: now &- startedAt, frameID: frameID,
            itemCount: itemCount, characterCount: characterCount, mode: mode
        )
        lock.withLock {
            guard active else { return }
            if spans.count < Self.maximumRawSpans || spans.count.isMultiple(of: 10) { spans.append(span) }
            counters["span.\(stage.rawValue)", default: 0] += 1
        }
    }

    func stop() -> SessionReport? {
        samplerTask?.cancel()
        samplerTask = nil
        sampleSystem()
        let snapshot: (Date, Date, UInt64, [ProfileSpan], [String: Int], [SystemSample], [OCRDiagnostic], (Int, Int)?, Bool)? = lock.withLock {
            guard active else { return nil }
            active = false
            sessionOwnerThread = nil
            return (startedAt, Date(), startedUptime, spans, counters, systemSamples, ocrDiagnostics, selectionPixels, benchmark)
        }
        guard let snapshot else { return nil }
        let metadata = ProfileMetadata(
            schemaVersion: 13, translationDirection: TranslationDirection.load().rawValue,
            startedAt: snapshot.0, endedAt: snapshot.1,
            durationSeconds: Double(DispatchTime.now().uptimeNanoseconds &- snapshot.2) / 1_000_000_000,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            selectionWidth: snapshot.7?.0, selectionHeight: snapshot.7?.1,
            benchmark: snapshot.8
        )
        let summaries = Self.summarize(snapshot.3)
        let counterValues = snapshot.4.sorted(by: { $0.key < $1.key }).map(ProfileCounter.init)
        let report = SessionReport(
            metadata: metadata, stages: summaries, counters: counterValues,
            systemSamples: snapshot.5, spans: snapshot.3, ocrDiagnostics: snapshot.6,
            recommendations: Self.recommendations(stages: summaries, counters: snapshot.4)
        )
        lock.withLock { mostRecentReport = report }
        return report
    }

    private func sampleSystem() {
        guard isActive else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let cpuTime = Self.processCPUTime()
        let sample = lock.withLock { () -> SystemSample in
            let wall = max(0.001, Double(now &- previousSampleUptime) / 1_000_000_000)
            let cpu = max(0, (cpuTime - previousCPUTime) / wall * 100)
            previousCPUTime = cpuTime
            previousSampleUptime = now
            return SystemSample(
                elapsedSeconds: Double(now &- startedUptime) / 1_000_000_000,
                cpuPercent: cpu,
                residentBytes: Self.residentMemory(),
                threadCount: Self.threadCount(),
                thermalState: Self.thermalStateName(ProcessInfo.processInfo.thermalState)
            )
        }
        lock.withLock { if active { systemSamples.append(sample) } }
    }

    private static func summarize(_ spans: [ProfileSpan]) -> [StageSummary] {
        ProfileStage.allCases.compactMap { stage in
            let values = spans.filter { $0.stage == stage }.map { Double($0.durationNanoseconds) / 1_000_000 }.sorted()
            guard !values.isEmpty else { return nil }
            return StageSummary(
                stage: stage, count: values.count, p50Milliseconds: percentile(values, 0.50),
                p95Milliseconds: percentile(values, 0.95), maxMilliseconds: values.last ?? 0,
                totalMilliseconds: values.reduce(0, +)
            )
        }.sorted { $0.totalMilliseconds > $1.totalMilliseconds }
    }

    private static func percentile(_ sorted: [Double], _ percentile: Double) -> Double {
        let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * percentile)) - 1))
        return sorted[index]
    }

    private static func recommendations(stages: [StageSummary], counters: [String: Int]) -> [String] {
        var result: [String] = []
        func stage(_ value: ProfileStage) -> StageSummary? { stages.first { $0.stage == value } }
        let ocrTotal = (stage(.ocrRealtime)?.totalMilliseconds ?? 0) + (stage(.ocrRefinement)?.totalMilliseconds ?? 0)
        if ocrTotal > (stages.first?.totalMilliseconds ?? 0) * 0.5 {
            result.append("OCR이 가장 큰 비중을 차지합니다. 미러의 프레임 일관성을 유지하면서 OCR 주기와 번역 캐시 적중률을 조정하세요.")
        }
        if let queue = stage(.translationQueue), queue.p95Milliseconds > 100 {
            result.append("번역 큐 대기가 큽니다. 원자적 미러 배치를 유지하면서 문장·segment 캐시 적중률을 확인하세요.")
        }
        if let refinement = stage(.ocrRefinement), refinement.count > 3,
           refinement.totalMilliseconds > (stage(.ocrRealtime)?.totalMilliseconds ?? 0) {
            result.append("보정 OCR 비중이 높습니다. 안정 화면당 1회 제한과 저신뢰 ROI 조건을 확인하세요.")
        }
        if let conversion = stage(.captureConversion), conversion.p95Milliseconds > 8 {
            result.append("화면 이미지 변환 비용이 높습니다. CVPixelBuffer 직접 처리와 저해상도 추적 버퍼를 검토하세요.")
        }
        if let draw = stage(.mirrorDraw), draw.p95Milliseconds > 16 {
            result.append("미러 그리기가 프레임 예산을 넘습니다. 이미지 합성과 창 크기를 줄이는 것을 검토하세요.")
        }
        if let composite = stage(.mirrorComposite), composite.p95Milliseconds > 16 {
            result.append("미러 네이티브 합성이 프레임 예산을 넘습니다. artwork 캐시 적중률과 캡처 pixel 크기를 확인하세요.")
        }
        let received = counters["frame.received", default: 0]
        let dropped = counters["frame.throttled", default: 0] + counters["frame.overwritten", default: 0]
        if received > 0, Double(dropped) / Double(received) > 0.15 {
            result.append("프레임 손실률이 15%를 넘습니다. 최신 프레임 처리량보다 캡처 해상도·빈도가 높습니다.")
        }
        if result.isEmpty { result.append("단일 지배 병목이 없습니다. end-to-end p95가 큰 세션을 더 길게 측정하세요.") }
        return Array(result.prefix(3))
    }

    private static func processCPUTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: list), vm_size_t(count) * vm_size_t(MemoryLayout<thread_t>.size))
        return Int(count)
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

enum ProfileReportWriter {
    static func jsonData(_ report: SessionReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    static func csvText(_ report: SessionReport) -> String {
        var csv = "stage,started_ns,duration_ms,frame_id,item_count,character_count,mode\n"
        for span in report.spans {
            csv += "\(span.stage.rawValue),\(span.startedNanoseconds),\(Double(span.durationNanoseconds) / 1_000_000),\(span.frameID.map(String.init) ?? ""),\(span.itemCount.map(String.init) ?? ""),\(span.characterCount.map(String.init) ?? ""),\(span.mode ?? "")\n"
        }
        return csv
    }

    static func save(_ report: SessionReport) throws -> (json: URL, csv: URL) {
        let manager = FileManager.default
        let base = try manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Rearview/ProfilingReports", isDirectory: true)
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseStem = "profile-\(formatter.string(from: report.metadata.startedAt))"
        var stem = baseStem
        var suffix = 1
        while manager.fileExists(atPath: base.appendingPathComponent(stem).appendingPathExtension("json").path)
            || manager.fileExists(atPath: base.appendingPathComponent(stem).appendingPathExtension("csv").path) {
            stem = "\(baseStem)-\(suffix)"
            suffix += 1
        }
        let jsonURL = base.appendingPathComponent(stem).appendingPathExtension("json")
        let csvURL = base.appendingPathComponent(stem).appendingPathExtension("csv")
        try jsonData(report).write(to: jsonURL, options: .atomic)
        try csvText(report).write(to: csvURL, atomically: true, encoding: .utf8)
        return (jsonURL, csvURL)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
