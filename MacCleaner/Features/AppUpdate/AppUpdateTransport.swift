import Foundation

/// The network access of Mac Cleaner's own update: the release lookup and the
/// download. Injectable, so tests never touch the network (they serve files from disk).
///
/// The live transport uses an ephemeral session (no cookies, cache or stored
/// credentials), refuses anything that isn't HTTPS, and follows HTTPS redirects only.
struct AppUpdateTransport: Sendable {
    /// Reports (bytes received, bytes expected) while downloading.
    typealias Progress = @Sendable (Int64, Int64?) -> Void

    /// Sends one request; returns the body and the HTTP response.
    var fetch: @Sendable (_ request: URLRequest, _ maxBytes: Int) async throws -> (Data, HTTPURLResponse)
    /// Downloads `url` to the file `destination`.
    var download: @Sendable (_ url: URL, _ destination: URL, _ maxBytes: Int64, _ progress: @escaping Progress) async throws -> Void

    static let live = AppUpdateTransport(
        fetch: { request, maxBytes in
            guard request.url?.scheme?.lowercased() == "https" else { throw AppUpdateError.insecureURL }
            let session = URLSession(configuration: AppUpdateTransport.configuration(timeout: request.timeoutInterval))
            defer { session.finishTasksAndInvalidate() }
            do {
                let (data, response) = try await session.data(for: request, delegate: AppUpdateHTTPSRedirects.shared)
                guard let http = response as? HTTPURLResponse else { throw AppUpdateError.network("The server's answer wasn't understood.") }
                guard data.count <= maxBytes else { throw AppUpdateError.tooLarge }
                return (data, http)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                throw AppUpdateError.network(AppUpdateTransport.describe(error))
            }
        },
        download: { url, destination, maxBytes, progress in
            guard url.scheme?.lowercased() == "https" else { throw AppUpdateError.insecureURL }
            try await AppUpdateDownloader.download(url, to: destination, maxBytes: maxBytes, progress: progress)
        }
    )

    /// An ephemeral session: no cookies, no URL cache, no credential storage.
    static func configuration(timeout: TimeInterval, resourceTimeout: TimeInterval? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout ?? timeout
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Plain-language network errors.
    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return "Your Mac appears to be offline."
        case .timedOut:
            return "GitHub didn't respond in time."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "GitHub couldn't be reached."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            return "GitHub's security certificate couldn't be verified, so the connection was stopped."
        default:
            return error.localizedDescription
        }
    }
}

/// Refuses redirects that leave HTTPS (release downloads redirect to GitHub's file servers).
final class AppUpdateHTTPSRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = AppUpdateHTTPSRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}

/// Downloads one file to disk with progress, cancellation and a size limit.
final class AppUpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let maxBytes: Int64
    private let progress: AppUpdateTransport.Progress
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, maxBytes: Int64, progress: @escaping AppUpdateTransport.Progress) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.progress = progress
    }

    static func download(_ url: URL, to destination: URL, maxBytes: Int64, progress: @escaping AppUpdateTransport.Progress) async throws {
        let downloader = AppUpdateDownloader(destination: destination, maxBytes: maxBytes, progress: progress)
        let configuration = AppUpdateTransport.configuration(timeout: 30, resourceTimeout: 30 * 60)
        let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue(AppUpdateChecker.userAgent(version: AppInfo.version), forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                downloader.lock.withLock { downloader.continuation = continuation }
                if Task.isCancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func finish(_ error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            lock.withLock { failure = AppUpdateError.tooLarge }
            downloadTask.cancel()
            return
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so it's moved right away.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            lock.withLock { failure = AppUpdateError.httpStatus(http.statusCode) }
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { failure = AppUpdateError.network("The download couldn't be saved: \(error.localizedDescription)") }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let recorded = lock.withLock { failure }
        if let recorded {
            finish(recorded)
        } else if let error = error as? URLError {
            finish(error.code == .cancelled ? CancellationError() : AppUpdateError.network(AppUpdateTransport.describe(error)))
        } else if let error {
            finish(AppUpdateError.network(error.localizedDescription))
        } else if !FileManager.default.fileExists(atPath: destination.path) {
            finish(AppUpdateError.network("The download didn't finish."))
        } else {
            finish(nil)
        }
    }
}
