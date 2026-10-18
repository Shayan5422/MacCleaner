import Foundation
import Observation

/// The guides the person marked as done, saved per guide in UserDefaults: `guides.done.<id>`
/// holds the date it was marked.
@MainActor
@Observable
final class GuideProgress {
    static let shared = GuideProgress()

    /// When this run of the app started. Recently Deleted suggestions come back after new deletions
    /// even if they were marked as done in an earlier run.
    let sessionStart: Date
    /// When each done guide was marked.
    private(set) var completed: [String: Date]

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, sessionStart: Date = Date()) {
        self.defaults = defaults
        self.sessionStart = sessionStart
        var completed: [String: Date] = [:]
        for guide in GuideLibrary.all {
            if let date = defaults.object(forKey: Self.key(for: guide.id)) as? Date { completed[guide.id] = date }
        }
        self.completed = completed
    }

    func isDone(_ id: String) -> Bool {
        completed[id] != nil
    }

    func setDone(_ done: Bool, for id: String) {
        if done {
            let date = Date()
            completed[id] = date
            defaults.set(date, forKey: Self.key(for: id))
        } else {
            completed[id] = nil
            defaults.removeObject(forKey: Self.key(for: id))
        }
    }

    static func key(for id: String) -> String {
        "guides.done." + id
    }
}
