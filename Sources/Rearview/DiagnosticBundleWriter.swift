import AppKit
import Foundation

struct DiagnosticExportOptions: Sendable {
    var includesContent = true
    var symptom = "other"
    var description = ""
    var includesRecentLogs = true
}
struct DiagnosticManifest: Codable, Sendable {
    struct Frame: Codable, Sendable {
        let id, session: UUID
        let frameID: UInt64
        let generation, revision: Int
        let task, receivedAt: UInt64
        let createdAt: Date
        let summary: [String:String]
        let omissions: [String]
        let files: [String]
    }
    let schemaVersion: Int
    let createdAt: Date
    let session: UUID
    let contentIncluded: Bool
    let recentLogsIncluded: Bool?
    let symptom, description: String
    let state: [String:String]
    let contentEnvironment: [String:String]?
    let current, displayed, failed: UUID?
    let omissions: [String]
    let frames: [Frame]
}
/// The archive contains only files generated here, never arbitrary filesystem trees.
enum DiagnosticBundleWriter {
    static let warning = "진단 파일에는 원본 화면 이미지, 문서 내용, 번역문 등이 포함될 수 있습니다. 민감한 정보가 포함되어 있지 않은지 확인한 후 개발자에게 전달해 주세요. 파일은 자동으로 전송되지 않습니다."
    static var temporaryRoot: URL { FileManager.default.temporaryDirectory.appendingPathComponent("RearviewDiagnosticExports",isDirectory:true) }
    static func cleanupOrphans() {
        let fm=FileManager.default
        guard let children=try? fm.contentsOfDirectory(at:temporaryRoot,includingPropertiesForKeys:nil) else { return }
        for child in children {
            let parts=child.lastPathComponent.split(separator:"-",maxSplits:1)
            guard parts.count==2, let pid=Int32(parts[0]), UUID(uuidString:String(parts[1])) != nil else { continue }
            if kill(pid,0) != 0 && errno == ESRCH { try? fm.removeItem(at:child) }
        }
    }
    static func write(_ snapshot:DiagnosticSnapshot, options:DiagnosticExportOptions, destination:URL) throws -> DiagnosticManifest {
        let fm=FileManager.default
        let working=temporaryRoot.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(UUID())",isDirectory:true)
        let payload=working.appendingPathComponent("diagnostics",isDirectory:true)
        defer { try? fm.removeItem(at:working) }
        try fm.createDirectory(at:payload,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:working.path)
        let result=try writeFolder(snapshot,options:options,to:payload)
        try Task.checkCancellation()
        // Stage beside the destination: rename is atomic, and a cancelled export never replaces an existing ZIP.
        let staged=destination.deletingLastPathComponent().appendingPathComponent(".Rearview-Diagnostics-\(UUID()).zip")
        defer { try? fm.removeItem(at:staged) }
        guard fm.createFile(atPath:staged.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw CocoaError(.fileWriteNoPermission) }
        let process=Process()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto")
        process.arguments=["-c","-k","--norsrc","--noextattr","--noqtn",payload.path,staged.path]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            if Task.isCancelled { process.terminate();process.waitUntilExit();throw CancellationError() }
            Thread.sleep(forTimeInterval:0.025)
        }
        process.waitUntilExit()
        guard process.terminationStatus==0 else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:staged.path)
        if fm.fileExists(atPath:destination.path) { _=try fm.replaceItemAt(destination,withItemAt:staged) }
        else { try fm.moveItem(at:staged,to:destination) }
        return result
    }
    @discardableResult static func writeFolder(_ snapshot:DiagnosticSnapshot,options:DiagnosticExportOptions,to folder:URL) throws -> DiagnosticManifest {
        let fm=FileManager.default
        try fm.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];encoder.dateEncodingStrategy = .iso8601
        var exported:[DiagnosticManifest.Frame]=[]
        var remaining=DiagnosticRecorder.maximumBytes
        let includesRecentLogs = options.includesRecentLogs
        let displayed = snapshot.frames.first { $0.id == snapshot.displayed }
        let frames = includesRecentLogs ? snapshot.frames : displayed.map { [$0] } ?? []
        for frame in frames {
            try Task.checkCancellation()
            var files:[String]=[],omissions=frame.omissions
            if frame.images["composite.png"] == nil { omissions.append("no_composite_available") }
            if options.includesContent {
                let directory=folder.appendingPathComponent(frame.id.uuidString,isDirectory:true)
                try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
                func save(_ name:String,_ data:Data) throws {
                    guard data.count<=remaining else { omissions.append("\(name):export_size_limit");return }
                    try data.write(to:directory.appendingPathComponent(name),options:.atomic)
                    remaining-=data.count;files.append(name)
                }
                for name in frame.documents.keys.sorted() {
                    try Task.checkCancellation()
                    do { try save(name,try frame.documents[name]!.encode()) }
                    catch is CancellationError { throw CancellationError() }
                    catch { omissions.append("\(name):serialization_or_write_failed") }
                }
                for name in frame.images.keys.sorted() {
                    try Task.checkCancellation()
                    do {
                        guard let data=NSBitmapImageRep(cgImage:frame.images[name]!).representation(using:.png,properties:[:]) else { omissions.append("\(name):image_encoding_failed");continue }
                        try save(name,data)
                    } catch { omissions.append("\(name):image_write_failed") }
                }
            } else { omissions.append("content_excluded_by_user") }
            exported.append(.init(id:frame.id,session:frame.session,frameID:frame.frameID,generation:frame.generation,revision:frame.revision,task:frame.task,receivedAt:frame.receivedAt,createdAt:frame.createdAt,summary:frame.summary,omissions:omissions,files:files))
        }
        let manifest=DiagnosticManifest(schemaVersion:snapshot.schemaVersion,createdAt:snapshot.createdAt,session:snapshot.session,
            contentIncluded:options.includesContent,recentLogsIncluded:includesRecentLogs,
            symptom:options.symptom,description:options.description,state:includesRecentLogs ? snapshot.state : [:],
            contentEnvironment:includesRecentLogs && options.includesContent ? snapshot.contentEnvironment : nil,
            current:includesRecentLogs ? snapshot.current : nil,displayed:includesRecentLogs ? snapshot.displayed : displayed?.id,
            failed:includesRecentLogs ? snapshot.failed : nil,
            omissions:includesRecentLogs ? snapshot.omissions : (displayed == nil ? ["no_displayed_frame"] : []),frames:exported)
        try encoder.encode(manifest).write(to:folder.appendingPathComponent("manifest.json"),options:.atomic)
        if includesRecentLogs || displayed != nil {
            let entries = includesRecentLogs ? snapshot.events : displayed?.scopedEvents ?? []
            var written = Set<UInt64>()
            // Events are a structural allowlist at source. No raw provider error strings are allowed here.
            var events=Data()
            let eventEncoder=JSONEncoder();eventEncoder.outputFormatting=[.sortedKeys];eventEncoder.dateEncodingStrategy = .iso8601
            for event in entries.sorted(by: { $0.sequence < $1.sequence }) where written.insert(event.sequence).inserted { events.append(try eventEncoder.encode(event));events.append(10) }
            try events.write(to:folder.appendingPathComponent("events.jsonl"),options:.atomic)
        }
        let scope = includesRecentLogs
            ? "수집 항목: 실행 환경, 설정, 최근 이벤트, 선택한 경우 화면·추출·번역·렌더링 결과."
            : "수집 항목: 표시 중인 프레임과 이 프레임이 참조한 프레임의 관련 이벤트, 선택한 경우 표시 중인 프레임의 화면·추출·번역·렌더링 결과."
        let readme=warning+"\n\n최근 로그 포함: \(includesRecentLogs)\n화면 내용 포함: \(options.includesContent)\n설명란은 내용 포함 설정과 관계없이 저장됩니다.\n"
            + "\n"+scope+"\n"
            + "\nDeveloper: inspect manifest.json and, when included, events.jsonl. Frame folders are UUIDs.\n"
        let replayInstructions = options.includesContent && !frames.isEmpty
            ? "\n재현은 저장된 결과의 렌더링에 한합니다. 대상 앱의 당시 상태나 번역 모델의 동일 결과는 보장하지 않습니다.\n"
                + "Use the development app --review-diagnostics <folder> --diagnostic-frame <UUID> --diagnostic-review-output <new folder>. No AX/OCR/model calls are made.\n"
            : ""
        try (readme + replayInstructions).write(to:folder.appendingPathComponent("README.txt"),atomically:true,encoding:.utf8)
        try Task.checkCancellation()
        return manifest
    }
}
