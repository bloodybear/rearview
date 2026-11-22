import AppKit
import XCTest
@testable import NotionAXCore

final class AXInternalTraversalTests: XCTestCase {
    private final class Access: AXTextAccess {
        var descriptions: [Int32: String] = [:]
        var calls = 0
        override func param(_ e: AXUIElement, _ name: String, _ input: CFTypeRef) -> CFTypeRef? {
            calls += 1
            let marker = input as! AXTextMarker
            let id = UnsafeRawPointer(AXTextMarkerGetBytePtr(marker)).loadUnaligned(fromByteOffset:4, as:Int32.self)
            lastParameterizedResult = descriptions[id] == nil ? -25202 : 0
            return descriptions[id].map { $0 as CFString }
        }
    }

    private func walk(_ descriptions: [Int32:String], root: String) -> (complete:Bool, diagnostic:[String:Any], calls:Int) {
        var bytes = [UInt8](repeating: 0, count: 56)
        for (offset, value) in [(0,Int32(2)),(4,Int32(1)),(8,Int32(-2)),(16,Int32(1))] {
            withUnsafeBytes(of:value.littleEndian) { bytes.replaceSubrange(offset..<offset+4, with:$0) }
        }
        bytes.replaceSubrange(20..<52, with:repeatElement(UInt8(65), count:32))
        let marker = bytes.withUnsafeBufferPointer { AXTextMarkerCreate(nil,$0.baseAddress!,$0.count) }
        let access = Access(); access.descriptions = descriptions
        let result = access.internalTree(AXUIElementCreateApplication(0), marker, root) { _ in [:] }
        return (result.complete,result.diagnostics,access.calls)
    }

    func testNodeLimitRecordsPendingNodesWithoutAdditionalQueries() {
        let children = (2...70).map(String.init).joined(separator:",")
        let result = walk(Dictionary(uniqueKeysWithValues:(2...70).map { (Int32($0),"id=\($0) genericContainer") }), root:"id=1 genericContainer child_ids=\(children)")
        XCTAssertFalse(result.complete)
        XCTAssertEqual(result.diagnostic["reasons"] as? [String],["node_limit"])
        XCTAssertEqual(result.diagnostic["visitedNodes"] as? Int,65)
        XCTAssertEqual((result.diagnostic["pendingNodeIDs"] as? [Int32])?.count,5)
        XCTAssertEqual(result.calls,64)
    }

    func testDepthLimitAndDescriptionFailuresAreDistinct() {
        let chain = Dictionary(uniqueKeysWithValues:(2...18).map { (Int32($0),"id=\($0) genericContainer child_ids=\($0+1)") })
        let depth = walk(chain,root:"id=1 genericContainer child_ids=2")
        XCTAssertFalse(depth.complete)
        XCTAssertEqual(depth.diagnostic["reasons"] as? [String],["depth_limit"])
        XCTAssertEqual(depth.diagnostic["maximumDepth"] as? Int,16)
        let missing = walk([:],root:"id=1 genericContainer child_ids=2")
        XCTAssertEqual(missing.diagnostic["reasons"] as? [String],["description_unavailable"])
        let issues = missing.diagnostic["issues"] as? [[String:Any]]
        XCTAssertEqual(issues?.first?["axResult"] as? String,"-25202")
        let mismatch = walk([2:"id=3 genericContainer"],root:"id=1 genericContainer child_ids=2")
        XCTAssertEqual(mismatch.diagnostic["reasons"] as? [String],["description_id_mismatch"])
    }

    func testCompleteTraversalHasNoStopReasons() {
        let result = walk([2:"id=2 genericContainer"],root:"id=1 genericContainer child_ids=2")
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.diagnostic["reasons"] as? [String],[])
        XCTAssertEqual(result.calls,1)
    }
}
