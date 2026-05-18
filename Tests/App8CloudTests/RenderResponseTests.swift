//
//  RenderResponseTests.swift
//  App8CloudTests
//

import XCTest
@testable import App8Cloud

final class RenderResponseTests: XCTestCase {

    func testDatasourcesNullDecodesAsNil() throws {
        let body = """
        {
          "servedVersion": "v1",
          "data": { "type": "screen" },
          "styles": null,
          "components": null,
          "datasources": null
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ScreenRenderResponse.self, from: body)
        XCTAssertEqual(response.servedVersion, "v1")
        XCTAssertNil(response.styles)
        XCTAssertNil(response.components)
        XCTAssertNil(response.datasources)
    }

    func testDatasourcesMissingDecodesAsNil() throws {
        let body = """
        { "servedVersion": "v1", "data": { "type": "screen" } }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ScreenRenderResponse.self, from: body)
        XCTAssertNil(response.datasources)
    }

    func testDatasourcesPopulatedDecodesAsDict() throws {
        let body = """
        {
          "servedVersion": "v2",
          "data": { "type": "screen" },
          "datasources": {
            "products/featured": [{ "id": 1 }, { "id": 2 }],
            "users/me": { "name": "alex" }
          }
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ScreenRenderResponse.self, from: body)
        XCTAssertEqual(response.datasources?.count, 2)
        XCTAssertNotNil(response.datasources?["products/featured"])
        XCTAssertNotNil(response.datasources?["users/me"])
    }

    func testStylesAndComponentsNullDecodesAsNil() throws {
        let body = """
        {
          "servedVersion": "v1",
          "data": { "type": "screen" },
          "styles": null,
          "components": null
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(ScreenRenderResponse.self, from: body)
        XCTAssertNil(response.styles)
        XCTAssertNil(response.components)
    }
}
