import Foundation

struct APIClient: Sendable {
    static let shared = APIClient()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 600
            self.session = URLSession(configuration: config)
        }
    }

    private var baseURL: URL { AppConfig.baseURL }

    // MARK: - JSON GET

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let fullURL = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: fullURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidURL }

        do {
            let (data, response) = try await session.data(from: url)
            try check(response: response, data: data)
            return try JSONDecoder.apiDecoder().decode(T.self, from: data)
        } catch let e as APIError {
            throw e
        } catch let e as URLError {
            throw APIError.network(e)
        } catch let e as DecodingError {
            throw APIError.decoding(e)
        }
    }

    private func check(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    // MARK: - Endpoints

    func modelStatus() async throws -> ModelStatus {
        try await get("api/model_status")
    }

    func summary() async throws -> Summary {
        try await get("api/summary")
    }

    func episodes(start: Date, end: Date) async throws -> EpisodesResponse {
        try await get("api/episodes", query: [
            URLQueryItem(name: "start", value: APIDate.spaced.string(from: start)),
            URLQueryItem(name: "end",   value: APIDate.spaced.string(from: end)),
        ])
    }

    func hourly(start: Date, end: Date) async throws -> HourlyResponse {
        try await get("api/hourly", query: [
            URLQueryItem(name: "start", value: APIDate.spaced.string(from: start)),
            URLQueryItem(name: "end",   value: APIDate.spaced.string(from: end)),
        ])
    }

    func ecgRaw(center: Date, windowSec: Int) async throws -> ECGRawWindow {
        try await get("api/ecg_raw", query: [
            URLQueryItem(name: "center", value: APIDate.iso.string(from: center)),
            URLQueryItem(name: "window", value: "\(windowSec)"),
        ])
    }

    func pvcBurden(granularity: Granularity, start: Date, end: Date) async throws -> PVCBurdenResponse {
        let fmt: DateFormatter = granularity == .day ? APIDate.day : APIDate.spaced
        return try await get("api/pvc_burden", query: [
            URLQueryItem(name: "granularity", value: granularity.rawValue),
            URLQueryItem(name: "start",       value: fmt.string(from: start)),
            URLQueryItem(name: "end",         value: fmt.string(from: end)),
        ])
    }

    // MARK: - Upload

    enum UploadResult {
        case accepted(sessionId: String)
        case skipped
    }

    /// POST /upload multipart. Returns `.accepted(sessionId)` when the server
    /// redirects to `/analyse/<id>`, or `.skipped` when it redirects back to
    /// `/upload` (server-side duplicate detection).
    func uploadRFile(fileURL: URL, filename: String) async throws -> UploadResult {
        let uploadURL = baseURL.appendingPathComponent("upload")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try buildMultipartBody(fileURL: fileURL, filename: filename, boundary: boundary)
        request.httpBody = body
        request.timeoutInterval = 600

        let delegate = RedirectCapturingDelegate()
        do {
            let (data, response) = try await session.data(for: request, delegate: delegate)

            if let loc = delegate.redirectLocation {
                if let id = extractSessionId(from: loc) {
                    return .accepted(sessionId: id)
                }
                // Flask redirects dupes back to /upload — treat that as skipped.
                if loc.path.hasSuffix("/upload") || loc.path == "/upload" {
                    return .skipped
                }
            }
            if let http = response as? HTTPURLResponse,
               http.statusCode == 200,
               let url = http.url,
               let id = extractSessionId(from: url) {
                return .accepted(sessionId: id)
            }

            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw APIError.http(code, String(data: data, encoding: .utf8))
        } catch let e as APIError {
            throw e
        } catch let e as URLError {
            throw APIError.network(e)
        }
    }

    private func buildMultipartBody(fileURL: URL, filename: String, boundary: String) throws -> Data {
        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func extractSessionId(from url: URL) -> String? {
        let parts = url.pathComponents
        if let idx = parts.firstIndex(of: "analyse"), idx + 1 < parts.count {
            return parts[idx + 1]
        }
        return nil
    }

    // MARK: - SSE

    /// Streams `/api/stream/<session_id>` server-sent events.
    /// Emits one `ProgressEvent` per event block; terminates the stream after
    /// receiving `done` or `error`.
    func streamProgress(sessionId: String) -> AsyncThrowingStream<ProgressEvent, Error> {
        let url = baseURL.appendingPathComponent("api/stream/\(sessionId)")
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 3600
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw APIError.http(http.statusCode, nil)
                    }

                    var eventName: String? = nil
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            eventName = nil
                            continue
                        }
                        if line.hasPrefix(":") {
                            continue
                        }
                        if line.hasPrefix("event:") {
                            eventName = String(line.dropFirst("event:".count))
                                .trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let data = String(line.dropFirst("data:".count))
                                .trimmingCharacters(in: .whitespaces)
                            let kindRaw = eventName ?? "message"
                            let kind = ProgressEvent.Kind(rawValue: kindRaw) ?? .message
                            continuation.yield(ProgressEvent(kind: kind, data: data))
                            if kind == .done || kind == .error {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class RedirectCapturingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var redirectLocation: URL?

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectLocation = request.url
        completionHandler(nil)
    }
}
