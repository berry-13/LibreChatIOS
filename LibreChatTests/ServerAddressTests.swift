import XCTest
@testable import LibreChat

final class ServerAddressTests: XCTestCase {
    func testAddsHTTPSAndNormalizesTrailingSlash() throws {
        let address = try ServerAddress.parse("  chat.example.com/  ")

        XCTAssertEqual(address.url.absoluteString, "https://chat.example.com")
    }

    func testPreservesReverseProxyBasePath() throws {
        let address = try ServerAddress.parse("https://example.com/librechat/")
        let endpoint = address.endpoint(
            "api/convos",
            queryItems: [URLQueryItem(name: "limit", value: "25")]
        )

        XCTAssertEqual(endpoint.absoluteString, "https://example.com/librechat/api/convos?limit=25")
    }

    func testRejectsRemoteHTTP() {
        XCTAssertThrowsError(try ServerAddress.parse("http://chat.example.com")) { error in
            XCTAssertEqual(error as? ServerAddressError, .insecureRemoteHost)
        }
    }

    func testAllowsLocalDevelopmentHTTP() throws {
        let address = try ServerAddress.parse("http://localhost:3080")

        XCTAssertEqual(address.url.absoluteString, "http://localhost:3080")
    }

    func testRemovesQueryAndFragmentFromBaseAddress() throws {
        let address = try ServerAddress.parse("https://chat.example.com/root?debug=1#section")

        XCTAssertEqual(address.url.absoluteString, "https://chat.example.com/root")
    }

    func testSharedLinkParserPreservesSelectedServerAndReverseProxyBoundary() throws {
        let baseURL = URL(string: "https://chat.example.com/librechat")!

        let shareID = try SharedLinkAddress.parse(
            "https://chat.example.com/librechat/share/share_SAFE-1",
            serverBaseURL: baseURL
        )

        XCTAssertEqual(shareID.rawValue, "share_SAFE-1")
        XCTAssertEqual(
            try SharedLinkAddress.parse("share_SAFE-1", serverBaseURL: baseURL),
            shareID
        )
    }

    func testSharedLinkParserRejectsAnotherOriginOrPath() {
        let baseURL = URL(string: "https://chat.example.com/librechat")!

        XCTAssertThrowsError(
            try SharedLinkAddress.parse(
                "https://other.example.com/librechat/share/share-1",
                serverBaseURL: baseURL
            )
        ) { error in
            XCTAssertEqual(error as? SharedLinkAddressError, .wrongServer)
        }
        XCTAssertThrowsError(
            try SharedLinkAddress.parse(
                "https://chat.example.com/share/share-1",
                serverBaseURL: baseURL
            )
        ) { error in
            XCTAssertEqual(error as? SharedLinkAddressError, .invalid)
        }
        XCTAssertThrowsError(
            try SharedLinkAddress.parse("../share/escape", serverBaseURL: baseURL)
        ) { error in
            XCTAssertEqual(error as? SharedLinkAddressError, .invalid)
        }
    }
}
