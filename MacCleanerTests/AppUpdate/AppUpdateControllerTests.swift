import Foundation
import Testing
@testable import MacCleaner

/// Counts requests and answers with a release JSON (or an error) that tests can change.
final class ScriptedTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var body = AppUpdateFixtures.releaseJSON()
    private var status = 200
    private var error: AppUpdateError?
    private var count = 0

    func answer(_ body: String, status: Int = 200) {
        lock.withLock {
            self.body = body
            self.status = status
            self.error = nil
        }
    }

    func fail(_ error: AppUpdateError) { lock.withLock { self.error = error } }
    var requestCount: Int { lock.withLock { count } }

    var transport: AppUpdateTransport {
        AppUpdateTransport(
            fetch: { [self] request, _ in
                let (body, status, error) = lock.withLock { () -> (String, Int, AppUpdateError?) in
                    count += 1
                    return (self.body, self.status, self.error)
                }
                if let error { throw error }
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
            },
            download: { _, _, _, _ in throw AppUpdateError.network("not used") }
        )
    }
}

@MainActor
struct AppUpdateControllerTests {
    private func makeController(version: String = "0.9.0", store: AppUpdateMemoryStore = AppUpdateMemoryStore(), transport: ScriptedTransport, now: Date = Date()) -> AppUpdateController {
        AppUpdateController(currentVersion: version, currentBuild: "1", transport: transport.transport, store: store, now: { now })
    }

    @Test func aManualCheckFindsAndRemembersAnUpdate() async throws {
        let store = AppUpdateMemoryStore()
        let transport = ScriptedTransport()
        let controller = makeController(store: store, transport: transport)
        #expect(controller.availableUpdate == nil)
        await controller.performCheck(manual: true)

        let release = try #require(controller.availableUpdate)
        #expect(release.version == "1.0.0")
        #expect(controller.phase == .finished(.updateAvailable(release)))
        #expect(controller.lastCheckDate != nil)
        #expect(controller.statusTitle == "Mac Cleaner 1.0.0 is available")
        #expect(store.object(forKey: AppUpdateController.Keys.latestRelease) != nil)

        // A new launch restores it without asking GitHub again.
        let relaunched = makeController(store: store, transport: transport)
        #expect(relaunched.availableUpdate?.version == "1.0.0")
        #expect(transport.requestCount == 1)
        // Once this build is that new, the stored release is dropped.
        let updated = makeController(version: "1.0.0", store: store, transport: transport)
        #expect(updated.availableUpdate == nil)
        #expect(store.object(forKey: AppUpdateController.Keys.latestRelease) == nil)
    }

    @Test func skippingHidesTheVersionUntilAManualCheckFindsItAgain() async throws {
        let transport = ScriptedTransport()
        let controller = makeController(transport: transport)
        await controller.performCheck(manual: false)
        let release = try #require(controller.availableUpdate)
        controller.skip(release)
        #expect(controller.availableUpdate == nil)
        #expect(controller.latestRelease?.version == "1.0.0")
        #expect(controller.isSkipped(release))

        // Automatic checks respect the skip.
        await controller.performCheck(manual: false)
        #expect(controller.availableUpdate == nil)
        // Choosing "Check for Updates…" shows it again.
        await controller.performCheck(manual: true)
        #expect(controller.availableUpdate?.version == "1.0.0")
    }

    @Test func automaticChecksRunOnlyWhenEnabledAndDue() async {
        let transport = ScriptedTransport()
        let store = AppUpdateMemoryStore()
        let now = Date()
        let controller = makeController(store: store, transport: transport, now: now)
        #expect(controller.automaticChecksEnabled)

        controller.automaticChecksEnabled = false
        #expect(store.object(forKey: AppUpdateController.Keys.automaticChecks) as? Bool == false)
        await controller.checkIfDue()
        #expect(transport.requestCount == 0)

        controller.automaticChecksEnabled = true
        await controller.checkIfDue()
        #expect(transport.requestCount == 1)
        // Checked moments ago: not due again for a day.
        await controller.checkIfDue()
        #expect(transport.requestCount == 1)

        #expect(AppUpdateController.isDue(lastCheck: nil, now: now))
        #expect(!AppUpdateController.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        #expect(AppUpdateController.isDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now))
        #expect(AppUpdateController.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "A clock that went backwards makes a check due")
    }

    @Test func automaticChecksStaySilentButManualChecksReport() async {
        let transport = ScriptedTransport()
        transport.answer(AppUpdateFixtures.releaseJSON(tag: "v0.9.0", assetVersion: "0.9.0"))
        let controller = makeController(transport: transport)
        await controller.performCheck(manual: false)
        #expect(controller.phase == .idle)
        #expect(controller.availableUpdate == nil)

        await controller.performCheck(manual: true)
        #expect(controller.phase == .finished(.upToDate(latest: "0.9.0")))
        #expect(controller.statusDetail.hasPrefix("You're up to date"))
    }

    @Test func failuresAreReportedButDontCountAsAChecks() async {
        let transport = ScriptedTransport()
        transport.fail(.network("Your Mac appears to be offline."))
        let controller = makeController(transport: transport)
        await controller.performCheck(manual: true)
        #expect(controller.phase == .finished(.failed("Your Mac appears to be offline.")))
        #expect(controller.lastCheckFailed)
        #expect(controller.lastCheckDate == nil)
        #expect(controller.lastFailure == "Your Mac appears to be offline.")
        #expect(controller.statusTitle == "Couldn't check for updates")

        transport.answer("{}", status: 404)
        await controller.performCheck(manual: true)
        #expect(controller.phase == .finished(.noReleases))
        #expect(controller.lastCheckDate != nil)
        #expect(controller.lastFailure == nil)
    }

    @Test func aSimulatedVersionNeverInstalls() async throws {
        let transport = ScriptedTransport()
        let controller = AppUpdateController(currentVersion: "0.9.0", currentBuild: "", transport: transport.transport, store: AppUpdateMemoryStore(), isSimulated: true)
        await controller.performCheck(manual: true)
        let release = try #require(controller.availableUpdate)
        controller.downloadAndInstall(release)
        #expect(controller.installPhase == .failed(AppUpdateError.simulatedVersion.localizedDescription))
        controller.resetInstall()
        #expect(controller.installPhase == .idle)
    }
}
