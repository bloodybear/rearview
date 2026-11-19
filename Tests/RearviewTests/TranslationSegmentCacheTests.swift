import XCTest
@testable import Rearview

final class TranslationSegmentCacheTests: XCTestCase {
    func testHitKeepsOldEntryAndRepeatedHitsMaintainOrder() {
        let cache = TranslationSegmentCache<Int>(capacity: 3)
        for key in 1...3 { cache.insert(String(key), for: key) }

        XCTAssertEqual(cache.value(for: 1), "1")
        XCTAssertEqual(cache.value(for: 1), "1")
        cache.insert("4", for: 4)
        XCTAssertNil(cache.value(for: 2))

        XCTAssertEqual(cache.value(for: 3), "3")
        cache.insert("5", for: 5)
        XCTAssertNil(cache.value(for: 1))
        XCTAssertEqual(cache.value(for: 3), "3")
    }

    func testUpdatingAnEntryAndClearingTheCache() {
        let cache = TranslationSegmentCache<Int>(capacity: 2)
        cache.insert("old", for: 1)
        cache.insert("two", for: 2)
        cache.insert("new", for: 1)
        cache.insert("three", for: 3)

        XCTAssertNil(cache.value(for: 2))
        XCTAssertEqual(cache.value(for: 1), "new")
        cache.removeAll()
        XCTAssertNil(cache.value(for: 1))
        XCTAssertNil(cache.value(for: 3))
        cache.insert("one", for: 1)
        XCTAssertEqual(cache.value(for: 1), "one")
    }

    func testSingleEntryCapacity() {
        let cache = TranslationSegmentCache<Int>(capacity: 1)
        cache.insert("one", for: 1)
        cache.insert("two", for: 2)
        XCTAssertNil(cache.value(for: 1))
        XCTAssertEqual(cache.value(for: 2), "two")
    }
}
