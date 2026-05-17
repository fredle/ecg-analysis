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
            URLQueryItem(name: "center", value: APIDate.spaced.string(from: center)),
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

    // MARK: - Upload (JSON API)

    struct UploadResponse: Decodable {
        let session_id: String
        let files: [String]
        let count: Int
        let status: String?  // "done" or "error"
        let error: String?
    }

    enum UploadResult {
        case done(sessionId: String)
        case error(sessionId: String, message: String)
        case skipped
    }

    /// POST /api/upload — uploads file and runs inference synchronously.
    /// May take 2-3 minutes per file for inference.
    func uploadRFile(fileURL: URL, filename: String) async throws -> UploadResult {
        let uploadURL = baseURL.appendingPathComponent("api/upload")
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 600

        let body = try buildMultipartBody(fileURL: fileURL, filename: filename, boundary: boundary)
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw APIError.http(0, nil)
            }

            if http.statusCode == 400 {
                return .skipped
            }

            try check(response: response, data: data)

            if let decoded = try? JSONDecoder().decode(UploadResponse.self, from: data) {
                if decoded.status == "error" {
                    return .error(sessionId: decoded.session_id, message: decoded.error ?? "Inference failed")
                }
                return .done(sessionId: decoded.session_id)
            }
            return .skipped
        } catch let e as APIError {
            throw e
        } catch let e as URLError {
            throw APIError.network(e)
        } catch let e as DecodingError {
            throw APIError.decoding(e)
        }
    }

    // MARK: - Inference

    struct InferenceResponse: Decodable {
        let session_id: String
        let status: String
    }

    /// POST /api/inference/<session_id> — kicks off inference and returns immediately.
    func startInference(sessionId: String) async throws {
        let url = baseURL.appendingPathComponent("api/inference/\(sessionId)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            try check(response: response, data: data)
        } catch let e as APIError {
            throw e
        } catch let e as URLError {
            throw APIError.network(e)
        }
    }

    struct InferenceStatus: Decodable {
        let session_id: String
        let status: String   // "pending", "processing", "done", "error"
        let error: String?
    }

    /// GET /api/inference/<session_id>/status — poll for inference progress.
    func inferenceStatus(sessionId: String) async throws -> InferenceStatus {
        try await get("api/inference/\(sessionId)/status")
    }

    // MARK: - Multipart helpers

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

    /// Write multipart body to a temp file for background upload tasks.
    static func writeMultipartFile(fileURL: URL, filename: String) throws -> (URL, String) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        let fileData = try Data(contentsOf: fileURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        try body.write(to: tmpURL)
        return (tmpURL, boundary)
    }

    // MARK: - SSE (kept for web compatibility)

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
