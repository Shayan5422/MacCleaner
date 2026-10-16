import Foundation

/// One HTTPS request made by the definitions updater.
struct AVHTTPRequest: Sendable {
    var url: URL
    var headers: [String: String] = [:]
    /// Bodies larger than this are refused (`tooLarge`), or cut off when `truncatesAtLimit`.
    var maxBytes: Int64
    /// Stop after `maxBytes` and report success (used to read a database header).
    var truncatesAtLimit = false
    /// Automatic updates don't use networks in Low Data Mode.
    var allowsConstrainedNetwork = true
    /// Seconds without data before the request fails.
    var idleTimeout: TimeInterval = 60

    init(url: URL, headers: [String: String] = [:], maxBytes: Int64, truncatesAtLimit: Bool = false) {
        self.url = url
        self.headers = headers
        self.maxBytes = maxBytes
        self.truncatesAtLimit = truncatesAtLimit
    }
}

struct AVHTTPResponse: Sendable {
    var statusCode: Int
    /// Header names in lower case.
    var headers: [String: String]
    var bytesReceived: Int64

    init(statusCode: Int, headers: [String: String] = [:], bytesReceived: Int64 = 0) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.bytesReceived = bytesReceived
    }

    var isSuccess: Bool { (200..<300).contains(statusCode) }
    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var etag: String? { header("etag") }
    var lastModified: String? { header("last-modified") }

    /// `Retry-After` as seconds from `now` (either form: delta-seconds or an HTTP date).
    func retryAfter(now: Date = Date()) -> TimeInterval? {
        guard let value = header("retry-after")?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

enum AVTransportError: LocalizedError, Sendable, Equatable {
    case insecureURL
    case tooLarge(Int64)
    case offline
    case timedOut
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .insecureURL: return "Only secure (HTTPS) downloads are allowed."
        case .tooLarge(let limit): return "The download was larger than expected (over \(ByteFormatting.string(limit))) and was stopped."
        case .offline: return "This Mac isn't connected to the internet."
        case .timedOut: return "The server didn't respond in time."
        case .cancelled: return "The download was stopped."
        case .failed(let detail): return detail
        }
    }

    /// Network problems that say nothing about the server (no backoff penalty beyond the usual retry).
    var isConnectivityProblem: Bool { self == .offline || self == .timedOut }
}

/// Sends HTTPS requests. `AVURLSessionTransport` is the real one; tests serve local files.
protocol AVHTTPTransport: Sendable {
    /// Downloads a successful (2xx) body into `destination` (replacing it). Other statuses return
    /// without writing anything. `progress` receives bytes so far and the expected total.
    func download(_ request: AVHTTPRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> AVHTTPResponse
    /// Fetches a small body into memory.
    func fetch(_ request: AVHTTPRequest) async throws -> (AVHTTPResponse, Data)
}

/// URLSession transport: ephemeral (no cookies, no cache, no credentials), HTTPS only (also for
/// redirects), with idle and total timeouts and response size caps.
struct AVURLSessionTransport: AVHTTPTransport {
    var totalTimeout: TimeInterval = 30 * 60

    init() {}

    func download(_ request: AVHTTPRequest, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> AVHTTPResponse {
        let (response, _) = try await perform(request, destination: destination, progress: progress)
        return response
    }

    func fetch(_ request: AVHTTPRequest) async throws -> (AVHTTPResponse, Data) {
        try await perform(request, destination: nil, progress: { _, _ in })
    }

    private func perform(_ request: AVHTTPRequest, destination: URL?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> (AVHTTPResponse, Data) {
        guard request.url.scheme?.lowercased() == "https", request.url.host != nil else { throw AVTransportError.insecureURL }
        try Task.checkCancellation()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = request.idleTimeout
        configuration.timeoutIntervalForResource = totalTimeout
        configuration.waitsForConnectivity = false
        configuration.allowsConstrainedNetworkAccess = request.allowsConstrainedNetwork
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let delegate = AVTransferDelegate(request: request, destination: destination, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(AVHTTPResponse, Data), Error>) in
                delegate.start(task: session.dataTask(with: urlRequest), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

/// Receives one transfer's callbacks (on the session's serial queue).
private final class AVTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let request: AVHTTPRequest
    private let destination: URL?
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(AVHTTPResponse, Data), Error>?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var buffer = Data()
    private var received: Int64 = 0
    private var expected: Int64?
    private var response: AVHTTPResponse?
    private var lastProgress = Date.distantPast
    private var cancelledByCaller = false

    init(request: AVHTTPRequest, destination: URL?, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.request = request
        self.destination = destination
        self.progress = progress
    }

    func start(task: URLSessionDataTask, continuation: CheckedContinuation<(AVHTTPResponse, Data), Error>) {
        lock.withLock {
            self.task = task
            self.continuation = continuation
        }
        task.resume()
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionDataTask? in
            cancelledByCaller = true
            return self.task
        }
        task?.cancel()
    }

    /// Completes the transfer once; later calls (a cancellation callback after an early finish) do nothing.
    private func finish(_ result: Result<(AVHTTPResponse, Data), Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<(AVHTTPResponse, Data), Error>? in
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        guard let pending else { return }
        try? handle?.close()
        handle = nil
        if case .failure = result, let destination { try? FileManager.default.removeItem(at: destination) }
        pending.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive urlResponse: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = urlResponse as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(AVTransportError.failed("The server sent an unexpected response.")))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let parsed = AVHTTPResponse(statusCode: http.statusCode, headers: headers)
        response = parsed
        guard parsed.isSuccess else {
            // Error bodies aren't needed; the status and headers (Retry-After) are enough.
            completionHandler(.cancel)
            finish(.success((parsed, Data())))
            return
        }
        expected = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        if let expected, expected > request.maxBytes, !request.truncatesAtLimit {
            completionHandler(.cancel)
            finish(.failure(AVTransportError.tooLarge(request.maxBytes)))
            return
        }
        if let destination {
            do {
                try? FileManager.default.removeItem(at: destination)
                guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw AVTransportError.failed("Couldn't create \(destination.lastPathComponent).")
                }
                handle = try FileHandle(forWritingTo: destination)
            } catch {
                completionHandler(.cancel)
                finish(.failure(error))
                return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard response?.isSuccess == true else { return }
        var chunk = data
        if received + Int64(chunk.count) > request.maxBytes {
            guard request.truncatesAtLimit else {
                dataTask.cancel()
                finish(.failure(AVTransportError.tooLarge(request.maxBytes)))
                return
            }
            chunk = chunk.prefix(Int(request.maxBytes - received))
        }
        do {
            if let handle { try handle.write(contentsOf: chunk) } else { buffer.append(chunk) }
        } catch {
            dataTask.cancel()
            finish(.failure(AVTransportError.failed("Couldn't save the download: \(error.localizedDescription)")))
            return
        }
        received += Int64(chunk.count)
        let now = Date()
        if now.timeIntervalSince(lastProgress) > 0.15 {
            lastProgress = now
            progress(received, expected)
        }
        if request.truncatesAtLimit && received >= request.maxBytes, var done = response {
            done.bytesReceived = received
            dataTask.cancel()
            finish(.success((done, buffer)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never follow a redirect to plain HTTP (the redirect response is returned instead).
        completionHandler(newRequest.url?.scheme?.lowercased() == "https" ? newRequest : nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let cancelled = lock.withLock { cancelledByCaller }
            let code = (error as? URLError)?.code
            switch code {
            case .cancelled?: finish(.failure(cancelled ? CancellationError() : AVTransportError.cancelled))
            case .notConnectedToInternet?, .networkConnectionLost?, .dataNotAllowed?, .internationalRoamingOff?, .cannotFindHost?, .dnsLookupFailed?:
                finish(.failure(AVTransportError.offline))
            case .timedOut?: finish(.failure(AVTransportError.timedOut))
            default: finish(.failure(AVTransportError.failed(error.localizedDescription)))
            }
            return
        }
        guard var done = response else {
            finish(.failure(AVTransportError.failed("The server closed the connection without a response.")))
            return
        }
        done.bytesReceived = received
        progress(received, expected)
        finish(.success((done, buffer)))
    }
}
