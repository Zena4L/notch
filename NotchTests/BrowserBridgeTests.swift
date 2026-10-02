import Foundation
import Testing
@testable import Notch

@MainActor
struct BrowserBridgeTests {
    // MARK: HTTP parsing

    @Test func parsesAPostWithABody() throws {
        let body = #"{"url":"https://example.com/a.pdf","filename":"a.pdf"}"#
        let raw = "POST /download?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: chrome-extension://abc\r\nX-Notch-Bridge: 1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request) = BridgeRequest.parse(Data(raw.utf8)) else { Issue.record("not parsed"); return }
        #expect(request.method == "POST")
        #expect(request.path == "/download")
        #expect(request.headers["origin"] == "chrome-extension://abc")
        #expect(request.headers["x-notch-bridge"] == "1")
        #expect(request.route == .download(BridgeDownload(url: "https://example.com/a.pdf", filename: "a.pdf")))
    }

    @Test func waitsForTheWholeRequest() {
        #expect(BridgeRequest.parse(Data("GET /ping HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
        #expect(BridgeRequest.parse(Data("POST /download HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)) == .incomplete)
    }

    @Test func rejectsMalformedAndOversizedRequests() {
        #expect(BridgeRequest.parse(Data("NONSENSE\r\n\r\n".utf8)) == .invalid)
        #expect(BridgeRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: -4\r\n\r\n".utf8)) == .invalid)
        #expect(BridgeRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)) == .tooLarge)
        #expect(BridgeRequest.parse(Data(repeating: 0x41, count: BridgeRequest.maxSize + 1)) == .tooLarge)
    }

    // MARK: Who may hand over downloads

    @Test func onlyExtensionsAndLocalToolsAreTrusted() {
        #expect(BridgeRequest.isAllowed(origin: "chrome-extension://abcdef"))
        #expect(BridgeRequest.isAllowed(origin: "moz-extension://1234-5678"))
        #expect(BridgeRequest.isAllowed(origin: nil))  // curl, scripts; web pages always send an Origin
        #expect(!BridgeRequest.isAllowed(origin: "https://evil.com"))
        #expect(!BridgeRequest.isAllowed(origin: "null"))
        #expect(!BridgeRequest.isAllowed(origin: "http://127.0.0.1:47821"))
    }

    @Test func routesRequests() {
        let body = Data(#"{"url":"https://example.com/a.zip"}"#.utf8)
        func route(_ method: String, _ path: String, _ headers: [String: String], _ body: Data = Data()) -> BridgeRequest.Route {
            BridgeRequest(method: method, path: path, headers: headers, body: body).route
        }
        let ext = ["origin": "chrome-extension://abc", "x-notch-bridge": "1"]
        #expect(route("POST", "/download", ext, body) == .download(BridgeDownload(url: "https://example.com/a.zip")))
        #expect(route("POST", "/download", ["origin": "https://evil.com", "x-notch-bridge": "1"], body) == .reject(403))
        #expect(route("POST", "/download", ["origin": "chrome-extension://abc"], body) == .reject(403))  // header missing
        #expect(route("POST", "/download", ext, Data("nope".utf8)) == .reject(400))
        #expect(route("GET", "/download", ext) == .reject(405))
        #expect(route("GET", "/ping", [:]) == .ping)
        #expect(route("GET", "/ping", ["origin": "https://evil.com"]) == .reject(403))
        #expect(route("OPTIONS", "/download", ext) == .preflight)
        #expect(route("OPTIONS", "/download", ["origin": "https://evil.com"]) == .reject(403))
        #expect(route("GET", "/", [:]) == .reject(404))
    }

    @Test func corsHeadersOnlyForExtensions() {
        let allowed = String(decoding: BridgeResponse(status: 204, origin: "moz-extension://x").data, as: UTF8.self)
        #expect(allowed.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        #expect(allowed.contains("Access-Control-Allow-Origin: moz-extension://x\r\n"))
        let refused = String(decoding: BridgeResponse(status: 403, origin: "https://evil.com").data, as: UTF8.self)
        #expect(!refused.contains("Access-Control-Allow-Origin"))
        let json = String(decoding: BridgeResponse(status: 200, json: ["accepted": true]).data, as: UTF8.self)
        #expect(json.hasSuffix("\r\n\r\n{\"accepted\":true}"))
    }
}

private extension BridgeRequest {
    var route: Route { BridgeRequest.route(self) }
}
