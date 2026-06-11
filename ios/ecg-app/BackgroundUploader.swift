import Foundation
import os

/// Manages background URL session uploads that continue even when the app is
/// suspended or terminated. Uses a delegate-based URLSession with a background
/// configuration so iOS keeps the transfer alive.
final class BackgroundUploader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploader()

    static let sessionIdentifier = "com.ecg-app.background-upload"

    private let logger = Logger(subsystem: "com.ecg-app", category: "BackgroundUploader")

    /// Called by the app delegate when the system relaunches the app for a
    /// completed background transfer.
    var systemCompletionHandler: (() -> Void)?

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Upload requests run inference inline; allow time for large recordings.
        // If the client still gives up, launch reconciliation recovers the state.
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Pending continuations keyed by taskDescription (which stores the recording filename).
    private var continuations: [String: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var responseData: [String: Data] = [:]
    private let lock = NSLock()

    /// Enqueue a background upload for a single R-file.
    /// Returns the parsed upload response once the server responds.
    func upload(fileURL: URL, filename: String) async throws -> APIClient.UploadResult {
        let (tmpURL, boundary) = try APIClient.writeMultipartFile(fileURL: fileURL, filename: filename)

        let uploadURL = AppConfig.baseURL.appendingPathComponent("api/upload")
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = session.uploadTask(with: request, fromFile: tmpURL)
        task.taskDescription = filename

        let (data, response) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
            lock.lock()
            continuations[filename] = cont
            responseData[filename] = Data()
            lock.unlock()
            task.resume()
        }

        // Clean up temp file
        try? FileManager.default.removeItem(at: tmpURL)

        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(0, nil)
        }

        if http.statusCode == 400 {
            return .skipped
        }

        if !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }

        if let decoded = try? JSONDecoder().decode(APIClient.UploadResponse.self, from: data) {
            if decoded.status == "error" {
                return .error(sessionId: decoded.session_id, message: decoded.error ?? "Inference failed")
            }
            if decoded.status == "pending" {
                return .pending(sessionId: decoded.session_id)
            }
            return .done(sessionId: decoded.session_id)
        }
        return .skipped
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let key = dataTask.taskDescription else { return }
        lock.lock()
        responseData[key, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let key = task.taskDescription else { return }
        lock.lock()
        let cont = continuations.removeValue(forKey: key)
        let data = responseData.removeValue(forKey: key) ?? Data()
        lock.unlock()

        if let error {
            logger.error("Background upload failed for \(key): \(error.localizedDescription)")
            cont?.resume(throwing: error)
        } else if let response = task.response {
            logger.info("Background upload completed for \(key)")
            cont?.resume(returning: (data, response))
        } else {
            cont?.resume(throwing: APIError.http(0, "No response"))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        logger.info("Background session finished events")
        DispatchQueue.main.async { [weak self] in
            self?.systemCompletionHandler?()
            self?.systemCompletionHandler = nil
        }
    }

    // Handle redirects: don't follow them, we want the JSON response
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
