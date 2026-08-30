@preconcurrency import ScreenCaptureKit
import AppKit
import CoreImage

func pixelAlignedCaptureRect(
    selection: CGRect, screenFrame: CGRect, backingScale: CGFloat
) -> CGRect {
    let scale = max(1, backingScale)
    let raw = CGRect(
        x: selection.minX - screenFrame.minX,
        y: screenFrame.maxY - selection.maxY,
        width: selection.width,
        height: selection.height
    )
    let minX = (raw.minX * scale).rounded() / scale
    let minY = (raw.minY * scale).rounded() / scale
    let maxX = (raw.maxX * scale).rounded() / scale
    let maxY = (raw.maxY * scale).rounded() / scale
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "Rearview.capture", qos: .userInteractive)
    private let stateLock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var onFrame: (@Sendable (CGImage, UInt64, UInt64) -> Void)?
    private var lastDelivery = ContinuousClock.now
    private var deliveryInterval: Duration = .milliseconds(30)
    private var nextFrameID: UInt64 = 0
    private var captureTarget: CaptureTarget = .allContent
    private var currentDisplayID: CGDirectDisplayID?
    private var currentPolicy = CapturePolicy()

    func start(
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        backingScale: CGFloat,
        selection: CGRect,
        target: CaptureTarget = .allContent,
        policy: CapturePolicy,
        onFrame: @escaping @Sendable (CGImage, UInt64, UInt64) -> Void
    ) async throws {
        self.onFrame = onFrame
        currentPolicy = policy
        setDeliveryPolicy(policy, resetClock: true)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw TranslatorError.noDisplay
            }
            let filter = try makeFilter(content: content, display: display, target: target)
            let scale = backingScale
            let sourceRect = pixelAlignedCaptureRect(
                selection: selection, screenFrame: screenFrame, backingScale: scale
            )
            PerformanceProfiler.shared.increment("capture.display")
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = max(1, Int((sourceRect.width * scale).rounded()))
            configuration.height = max(1, Int((sourceRect.height * scale).rounded()))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(policy.targetFPS))
            configuration.queueDepth = 2
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            PerformanceProfiler.shared.setSelection(width: configuration.width, height: configuration.height)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            self.stream = stream
            self.configuration = configuration
            captureTarget = target
            currentDisplayID = displayID
            try await stream.startCapture()
            record(policy, target: target)
        } catch {
            // start() is a transaction: a failure at any phase must not leave
            // a callback, stream, or configuration owned by this engine.
            await stop()
            throw error
        }
    }

    func update(policy: CapturePolicy) async throws {
        currentPolicy = policy
        guard let stream, let configuration else {
            setDeliveryPolicy(policy, resetClock: true)
            record(policy, target: captureTarget)
            return
        }
        let previousInterval = configuration.minimumFrameInterval
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(policy.targetFPS)
        )
        do {
            try await stream.updateConfiguration(configuration)
        } catch {
            configuration.minimumFrameInterval = previousInterval
            throw error
        }
        setDeliveryPolicy(policy, resetClock: true)
        record(policy, target: captureTarget)
    }

    func updateRegion(
        selection: CGRect, screenFrame: CGRect, backingScale: CGFloat,
        displayID: CGDirectDisplayID? = nil
    ) async throws {
        guard let stream, let configuration else { return }
        if let displayID, displayID != currentDisplayID {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw TranslatorError.noDisplay
            }
            let filter = try makeFilter(content: content, display: display, target: captureTarget)
            try await stream.updateContentFilter(filter)
            currentDisplayID = displayID
        }
        let sourceRect = pixelAlignedCaptureRect(
            selection: selection, screenFrame: screenFrame, backingScale: backingScale
        )
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int((sourceRect.width * backingScale).rounded()))
        configuration.height = max(1, Int((sourceRect.height * backingScale).rounded()))
        try await stream.updateConfiguration(configuration)
        PerformanceProfiler.shared.setSelection(width: configuration.width, height: configuration.height)
    }

    func updateTarget(displayID: CGDirectDisplayID, target: CaptureTarget) async throws {
        guard let stream else {
            captureTarget = target
            return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw TranslatorError.noDisplay
        }
        let filter = try makeFilter(content: content, display: display, target: target)
        try await stream.updateContentFilter(filter)
        captureTarget = target
        record(currentPolicy, target: target)
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
            try? stream.removeStreamOutput(self, type: .screen)
        }
        self.stream = nil
        configuration = nil
        onFrame = nil
        captureTarget = .allContent
        currentDisplayID = nil
    }

    var isCleanForSelfTest: Bool {
        stream == nil
            && configuration == nil
            && onFrame == nil
            && captureTarget == .allContent
            && currentDisplayID == nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        PerformanceProfiler.shared.increment("frame.received")
        let now = ContinuousClock.now
        guard shouldDeliver(at: now) else {
            PerformanceProfiler.shared.increment("frame.throttled")
            return
        }
        nextFrameID &+= 1
        let frameID = nextFrameID
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        let conversion = PerformanceProfiler.shared.begin(.captureConversion, frameID: frameID)
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            PerformanceProfiler.shared.end(conversion)
            return
        }
        PerformanceProfiler.shared.end(conversion)
        onFrame?(cgImage, frameID, receivedAt)
    }

    private func record(_ policy: CapturePolicy, target: CaptureTarget) {
        let profiler = PerformanceProfiler.shared
        profiler.setCounter("capture.targetFPS", value: policy.targetFPS)
        profiler.setCounter(
            "ocr.realtimeIntervalMilliseconds",
            value: policy.realtimeOCRIntervalMilliseconds
        )
        profiler.setCounter("capture.mode.mirror", value: 1)
        profiler.setCounter("capture.filter.application", value: target.isApplication ? 1 : 0)
    }

    private func makeFilter(
        content: SCShareableContent, display: SCDisplay, target: CaptureTarget
    ) throws -> SCContentFilter {
        switch target {
        case .allContent:
            let currentApp = content.applications.filter { $0.processID == getpid() }
            return SCContentFilter(
                display: display, excludingApplications: currentApp, exceptingWindows: []
            )
        case .application(let targetApplication):
            guard let application = content.applications.first(where: {
                $0.processID == targetApplication.processID
            }) else {
                throw TranslatorError.captureApplicationUnavailable(targetApplication.name)
            }
            return SCContentFilter(
                display: display, including: [application], exceptingWindows: []
            )
        }
    }

    private func setDeliveryPolicy(_ policy: CapturePolicy, resetClock: Bool) {
        stateLock.lock()
        deliveryInterval = policy.deliveryInterval
        if resetClock { lastDelivery = .now - policy.deliveryInterval }
        stateLock.unlock()
    }

    private func shouldDeliver(at now: ContinuousClock.Instant) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard lastDelivery.duration(to: now) >= deliveryInterval else { return false }
        lastDelivery = now
        return true
    }
}

private extension CaptureTarget {
    var isApplication: Bool {
        if case .application = self { return true }
        return false
    }
}
