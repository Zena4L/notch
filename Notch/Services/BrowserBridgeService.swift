import Foundation
import Network
import Observation

/// Lets the Notch browser extension hand over downloads you click in Chrome or Firefox.
///
/// A tiny HTTP server on 127.0.0.1 (never reachable from other machines), only while
/// Settings › Activities › Downloads › "Take over downloads from your browser" is on.
/// Web pages can also send requests to localhost, so downloads are only accepted from
/// extension origins (or local tools that send no Origin at all) carrying the
/// `X-Notch-Bridge` header, which a page can't add without a CORS preflight we refuse.
@Observable
final class BrowserBridgeService {
    /// Must match `PORT` in Extension/background.js.
    static let port: UInt16 = 47821

    /// When the extension last checked in this session.
    private(set) var lastSeen: Date?
    private(set) var problem: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let downloads: DownloadService
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(settings: SettingsStore, downloads: DownloadService) {
        self.settings = settings
        self.downloads = downloads
        observer = NotificationCenter.default.addObserver(forName: .settingsDidChange, object: nil, queue: .main) { [weak self] note in
            guard note.affects(["browserTakeover", "downloadsEnabled"]) else { return }
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        let on = settings.browserTakeover && settings.downloadsEnabled
        if on, listener == nil {
            start()
        } else if !on, let listener {
            listener.cancel()
            self.listener = nil
            problem = nil
        }
    }

    private func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.problem = nil
                    case .failed(let error):
                        self?.problem = "Couldn't listen on port \(Self.port): \(error.localizedDescription)"
                        self?.listener?.cancel()
                        self?.listener = nil
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = "Couldn't listen on port \(Self.port): \(error.localizedDescription)"
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: BridgeRequest.maxSize) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch BridgeRequest.parse(buffer) {
                case .incomplete where !isComplete && error == nil:
                    self.receive(connection, buffer: buffer)
                case .incomplete, .invalid:
                    self.send(BridgeResponse(status: 400), on: connection)
                case .tooLarge:
                    self.send(BridgeResponse(status: 413), on: connection)
                case .complete(let request):
                    self.handle(request, on: connection)
                }
            }
        }
    }

    private func handle(_ request: BridgeRequest, on connection: NWConnection) {
        let origin = request.headers["origin"]
        switch BridgeRequest.route(request) {
        case .reject(let status):
            send(BridgeResponse(status: status), on: connection)
        case .preflight:
            send(BridgeResponse(status: 204, origin: origin), on: connection)
        case .ping:
            if origin != nil { lastSeen = .now }
            send(BridgeResponse(status: 200, origin: origin, json: ["ok": true, "enabled": settings.browserTakeover]), on: connection)
        case .download(let download):
            lastSeen = .now
            Task {
                let accepted = await downloads.takeOver(download)
                send(BridgeResponse(status: 200, origin: origin, json: ["accepted": accepted]), on: connection)
            }
        }
    }

    private func send(_ response: BridgeResponse, on connection: NWConnection) {
        connection.send(content: response.data, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - HTTP

/// Just enough HTTP/1.1 for the extension: one request per connection, small JSON bodies.
nonisolated struct BridgeRequest: Equatable {
    var method: String
    var path: String
    /// Lowercased names.
    var headers: [String: String]
    var body: Data

    enum Parse: Equatable {
        case incomplete, invalid, tooLarge
        case complete(BridgeRequest)
    }

    enum Route: Equatable {
        case preflight, ping
        case download(BridgeDownload)
        case reject(Int)
    }

    static let maxSize = 64 * 1024

    static func parse(_ data: Data) -> Parse {
        guard data.count <= maxSize else { return .tooLarge }
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let value = headers["content-length"] {
            guard let n = Int(value), n >= 0 else { return .invalid }
            length = n
        }
        guard length <= maxSize else { return .tooLarge }
        let available = data.distance(from: end.upperBound, to: data.endIndex)
        guard available >= length else { return .incomplete }
        let bodyEnd = data.index(end.upperBound, offsetBy: length)

        let target = String(requestLine[1])
        return .complete(BridgeRequest(
            method: String(requestLine[0]).uppercased(),
            path: String(target.split(separator: "?", maxSplits: 1).first ?? ""),
            headers: headers,
            body: Data(data[end.upperBound..<bodyEnd])
        ))
    }

    /// Browser extensions, or local tools that send no Origin. Web pages always send theirs.
    static func isAllowed(origin: String?) -> Bool {
        guard let origin else { return true }
        return origin.hasPrefix("chrome-extension://") || origin.hasPrefix("moz-extension://")
    }

    static func route(_ request: BridgeRequest) -> Route {
        let trusted = isAllowed(origin: request.headers["origin"])
        switch (request.method, request.path) {
        case ("OPTIONS", _):
            return trusted ? .preflight : .reject(403)
        case ("GET", "/ping"):
            return trusted ? .ping : .reject(403)
        case ("POST", "/download"):
            guard trusted, request.headers["x-notch-bridge"] == "1" else { return .reject(403) }
            guard let download = try? JSONDecoder().decode(BridgeDownload.self, from: request.body) else { return .reject(400) }
            return .download(download)
        case (_, "/ping"), (_, "/download"):
            return .reject(405)
        default:
            return .reject(404)
        }
    }
}

nonisolated struct BridgeResponse {
    var status: Int
    var origin: String?
    var json: [String: Bool] = [:]

    var data: Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let origin, BridgeRequest.isAllowed(origin: origin) {
            head += "Access-Control-Allow-Origin: \(origin)\r\n"
            head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: Content-Type, X-Notch-Bridge\r\n"
            head += "Access-Control-Allow-Private-Network: true\r\n"
        }
        return Data((head + "\r\n").utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        default: "Error"
        }
    }
}
