import Foundation
@testable import MacCleanerMobile

/// Answers requests from fixtures, never the network, and records them.
final class FixtureTransport: FeedTransport, @unchecked Sendable {
    struct Answer {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var answers: [URL: Answer]
    private var recorded: [URLRequest] = []

    init(_ answers: [URL: Answer]) {
        self.answers = answers
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func requests(to url: URL) -> [URLRequest] {
        requests.filter { $0.url == url }
    }

    func answer(_ url: URL, with answer: Answer) {
        lock.withLock { answers[url] = answer }
    }

    /// Unknown addresses fail as if offline.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer: Answer? = lock.withLock {
            recorded.append(request)
            return request.url.flatMap { answers[$0] }
        }
        guard let answer, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers) else {
            throw URLError(.notConnectedToInternet)
        }
        return (Data(answer.body.utf8), response)
    }
}

/// A clock the test moves forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date { lock.withLock { current } }

    func advance(hours: Double) {
        lock.withLock { current = current.addingTimeInterval(hours * 3600) }
    }
}

/// A Protection folder of its own in the temporary directory.
func temporaryProtectionStorage() -> ProtectionStorage {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("protection-\(UUID().uuidString)", isDirectory: true)
    return ProtectionStorage(directory: folder.appendingPathComponent("Protection", isDirectory: true),
                             blockerListURL: folder.appendingPathComponent("blockerList.json"))
}
