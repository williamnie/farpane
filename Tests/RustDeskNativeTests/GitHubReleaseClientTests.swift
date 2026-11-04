import Foundation
import XCTest

@testable import RustDeskNative

final class GitHubReleaseClientTests: XCTestCase {
    func testRequestUsesPublicReleaseListAndDecodesResponse() async throws {
        let client = makeClient(
            status: 200,
            body: """
                [{"tag_name":"v0.2.14","draft":false,"prerelease":true,
                  "assets":[{"name":"FarPane-v0.2.14-macos-arm64.dmg","state":"uploaded","size":123}]}]
                """)
        let releases = try await client.fetch()
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].tagName, "v0.2.14")
        XCTAssertTrue(releases[0].prerelease)
        XCTAssertTrue(releases[0].hasMacInstaller(architecture: "arm64"))
    }

    func testRateLimitAndServerFailureAreNotEmptySuccessfulLists() async {
        for status in [403, 404, 429, 500] {
            let client = makeClient(status: status, body: "[]")
            do {
                _ = try await client.fetch()
                XCTFail("HTTP \(status) must fail")
            } catch ReleaseCheckError.httpStatus(let code) { XCTAssertEqual(code, status) } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInvalidResponseIsNotReportedAsLatest() async {
        for body in ["<html>proxy error</html>", "{}", "[{\"tag_name\":\"v0.2.14\"}]"] {
            do {
                _ = try await makeClient(status: 200, body: body).fetch()
                XCTFail("Malformed response must fail")
            } catch {}
        }
    }

    private func makeClient(status: Int, body: String) -> GitHubReleaseClient {
        ReleaseURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.github.com/repos/williamnie/farpane/releases?per_page=100")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            return (
                HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: nil)!, Data(body.utf8)
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return GitHubReleaseClient(session: session)
    }
}

private final class ReleaseURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (response, data) = Self.handler?(request) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
