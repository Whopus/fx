import XCTest
@testable import Curatez

final class ContextTaobaoSearchTests: XCTestCase {
    func testTaobaoCallExtractsNestedSearchSubjectAndMetadata() {
        let call = ContextTaobaoSearchCall.parse(.object([
            "endpoint_id": .string("taobao.search_item_list_v1"),
            "params": .object([
                "keyword": .string("咖啡机"),
                "page": .number(2),
                "start_price": .string("100"),
                "end_price": .string("500")
            ])
        ]))

        XCTAssertEqual(call?.action, "Search products")
        XCTAssertEqual(call?.subject, "咖啡机")
        XCTAssertEqual(call?.metadata, "page 2 · ¥100–¥500")
    }

    func testTaobaoResultReadsBothLiveAndPersistedPresentationShapes() {
        let presentation: JSONValue = .object([
            "platform": .string("taobao"),
            "kind": .string("product-list"),
            "summary": .object(["count": .number(1)]),
            "data": .object([
                "items": .array([.object([
                    "id": .string("1001"),
                    "title": .string("咖啡机")
                ])])
            ])
        ])
        let persisted: JSONValue = .object(["presentation": presentation])
        let live: JSONValue = .object(["details": persisted])

        XCTAssertEqual(ContextTaobaoSearchResult.parse(persisted)?.kind, "product-list")
        XCTAssertEqual(ContextTaobaoSearchResult.parse(live)?.kind, "product-list")
        XCTAssertEqual(ContextTaobaoSearchResult.parse(live)?.summary["count"], .number(1))
    }

    func testNonTaobaoCallsKeepTheGenericToolRenderer() {
        let call = ContextTaobaoSearchCall.parse(.object([
            "endpoint_id": .string("xiaohongshu.search_note_v4"),
            "params": .object(["keyword": .string("咖啡")])
        ]))

        XCTAssertNil(call)
    }
}
