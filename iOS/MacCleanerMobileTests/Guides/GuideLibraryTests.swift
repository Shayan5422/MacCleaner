import Foundation
import Testing
@testable import MacCleanerMobile

private let iPhone = DeviceInfo(modelIdentifier: "iPhone18,3", systemVersion: [27, 0, 1], isPad: false)
private let iPhoneOn17 = DeviceInfo(modelIdentifier: "iPhone14,2", systemVersion: [17, 6, 1], isPad: false)
private let iPad = DeviceInfo(modelIdentifier: "iPad16,3", systemVersion: [27, 0, 0], isPad: true)

private func context(device: DeviceInfo = iPhone, storage: DeviceStorage? = DeviceStorage(total: 256_000_000_000, available: 120_000_000_000),
                     deletedPhotos: Bool = false, deletedFiles: Bool = false, safari: Bool? = true, upToDate: Bool? = true,
                     passcode: Bool? = true, available: String? = nil) -> GuideContext {
    GuideContext(storage: storage, device: device, deletedPhotos: deletedPhotos, deletedFiles: deletedFiles,
                 safariProtectionEnabled: safari, systemUpToDate: upToDate, passcodeSet: passcode, availableSystemVersion: available)
}

private func ids(_ context: GuideContext, completed: [String: Date] = [:], sessionStart: Date = .distantPast) -> [String] {
    GuideLibrary.suggestions(for: context, completed: completed, sessionStart: sessionStart).map(\.id)
}

private let lowStorage = DeviceStorage(total: 128_000_000_000, available: 3_000_000_000)

struct GuideContentTests {
    @Test func everyGuideHasStepsForIOS17And18AndLater() {
        for guide in GuideLibrary.all {
            for major in [17, 18, 26, 27] {
                let steps = guide.steps(forSystemMajorVersion: major)
                #expect(steps.count >= 2, "\(guide.id) on iOS \(major)")
                #expect(steps.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(guide.id)")
            }
        }
    }

    @Test func iOS17StepsNeverUseTheAppsPage() {
        // Settings › Apps arrived in iOS 18; on iOS 17, apps' settings are at the top level.
        for guide in GuideLibrary.all {
            let old = guide.steps(forSystemMajorVersion: 17).joined(separator: " ")
            #expect(!old.contains("Settings › Apps"), "\(guide.id)")
            if guide.steps.joined().contains("Settings › Apps") {
                #expect(guide.iOS17Steps != nil, "\(guide.id) needs iOS 17 steps")
            }
        }
    }

    @Test func appSettingsLiveUnderAppsFromIOS18() {
        for key in [GuideKey.safariHistory, .safariTabs, .safariProtection, .messagesHistory, .offloadApps, .optimizePhotos] {
            let guide = GuideLibrary.guide(key)
            #expect(guide.steps.first?.contains("Settings › Apps ›") == true, "\(guide.id)")
            #expect(guide.iOS17Steps?.first?.contains("Settings ›") == true, "\(guide.id)")
        }
    }

    @Test func theLibraryIsComplete() {
        let ids = GuideLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(GuideKey.allCases.map(\.rawValue)))
        #expect(GuideLibrary.all.count >= 17)
        for category in GuideCategory.allCases {
            #expect(!GuideLibrary.guides(in: category, for: iPhone).isEmpty)
        }
    }

    @Test func everyGuideSaysWhyAndWhatItDoes() {
        for guide in GuideLibrary.all {
            #expect(!guide.title.isEmpty && !guide.summary.isEmpty && !guide.why.isEmpty && !guide.benefit.isEmpty, "\(guide.id)")
            // The Overview shows titles and summaries as they are.
            #expect(!guide.title.contains("{") && !guide.summary.contains("{"), "\(guide.id)")
        }
    }

    @Test func placeholdersAreFilledIn() {
        for guide in GuideLibrary.all {
            for device in [iPhone, iPad, iPhoneOn17] {
                let texts = [guide.why, guide.benefit, guide.note ?? ""] + guide.steps(forSystemMajorVersion: device.systemMajorVersion)
                for text in texts {
                    let filled = Guide.text(text, for: device)
                    #expect(!filled.contains("{") && !filled.contains("}"), "\(guide.id): \(filled)")
                    // "an iPhone", "an iPad".
                    #expect(!filled.contains(" a iP") && !filled.contains("A iP"), "\(guide.id): \(filled)")
                }
            }
        }
        #expect(Guide.text("Settings › General › {device} Storage", for: iPad) == "Settings › General › iPad Storage")
        #expect(Guide.text("{system} updates", for: iPad) == "iPadOS updates")
    }

    @Test func stepsRenderTheirMarkdown() {
        for guide in GuideLibrary.all {
            for step in guide.steps(forSystemMajorVersion: 27) {
                let rendered = String(GuideMarkdown.render(step, for: iPhone).characters)
                #expect(!rendered.contains("**"), "\(guide.id): \(rendered)")
            }
        }
    }

    @Test func onlyThePrivacyGuideOpensAppSettings() {
        #expect(GuideLibrary.all.filter(\.opensAppSettings).map(\.id) == [GuideKey.privacyAccess.rawValue])
    }

    @Test func iPadsDontGetIPhoneOnlyGuides() {
        #expect(!GuideLibrary.guides(in: .security, for: iPad).contains { $0.id == GuideKey.stolenDeviceProtection.rawValue })
        #expect(GuideLibrary.guides(in: .security, for: iPhone).contains { $0.id == GuideKey.stolenDeviceProtection.rawValue })
    }

    @Test func searchMatchesEveryWord() {
        #expect(GuideLibrary.search("recently deleted", for: iPhone).map(\.id).prefix(2)
            == [GuideKey.photosRecentlyDeleted.rawValue, GuideKey.filesRecentlyDeleted.rawValue])
        #expect(GuideLibrary.search("WhatsApp", for: iPhone).map(\.id) == [GuideKey.chatAppMedia.rawValue])
        #expect(GuideLibrary.search("Stolen", for: iPhone).first?.id == GuideKey.passcode.rawValue)
        #expect(!GuideLibrary.search("Stolen", for: iPad).contains { $0.id == GuideKey.stolenDeviceProtection.rawValue })
        #expect(GuideLibrary.search("   ", for: iPhone).isEmpty)
        #expect(GuideLibrary.search("zzz nothing", for: iPhone).isEmpty)
    }
}

struct GuideSuggestionTests {
    @Test func deletedPhotosComeFirst() {
        let suggested = ids(context(deletedPhotos: true, deletedFiles: true, safari: false, upToDate: false, passcode: false))
        #expect(Array(suggested.prefix(5)) == [
            GuideKey.photosRecentlyDeleted, .filesRecentlyDeleted, .passcode, .updateSystem, .safariProtection,
        ].map(\.rawValue))
    }

    @Test func protectionProblemsComeBeforeTheDefaults() {
        #expect(ids(context(passcode: false)).first == GuideKey.passcode.rawValue)
        #expect(ids(context(upToDate: false)).first == GuideKey.updateSystem.rawValue)
        #expect(ids(context(safari: false)).first == GuideKey.safariProtection.rawValue)
        #expect(Array(ids(context(safari: false, upToDate: false)).prefix(2))
            == [GuideKey.updateSystem.rawValue, GuideKey.safariProtection.rawValue])
    }

    @Test func lowStorageBringsTheSpaceGuidesUp() {
        let suggested = ids(context(storage: lowStorage))
        #expect(Array(suggested.prefix(GuideLibrary.spaceOrder.count)) == GuideLibrary.spaceOrder.map(\.rawValue))
        #expect(ids(context(storage: lowStorage, deletedFiles: true)).first == GuideKey.filesRecentlyDeleted.rawValue)
    }

    @Test func aHealthyDeviceGetsTheDefaultOrder() {
        let suggested = ids(context())
        #expect(Array(suggested.prefix(3)) == [GuideKey.stolenDeviceProtection, .offloadApps, .optimizePhotos].map(\.rawValue))
        // Nothing to fix: no passcode, update or Safari guide, and never Lockdown Mode.
        for key in [GuideKey.passcode, .updateSystem, .safariProtection, .lockdownMode] {
            #expect(!suggested.contains(key.rawValue), "\(key)")
        }
    }

    @Test func safariProtectionIsSuggestedWhileItsStateIsUnknown() {
        #expect(Array(ids(context(safari: nil)).prefix(2)) == [GuideKey.stolenDeviceProtection, .safariProtection].map(\.rawValue))
    }

    @Test func iPadsSkipIPhoneOnlyGuides() {
        #expect(ids(context(device: iPad)).first == GuideKey.offloadApps.rawValue)
    }

    @Test func doneGuidesLeaveTheSuggestions() {
        let done = [GuideKey.stolenDeviceProtection.rawValue: Date(timeIntervalSince1970: 1_000)]
        #expect(ids(context(), completed: done).first == GuideKey.offloadApps.rawValue)
        #expect(!ids(context(storage: lowStorage), completed: [GuideKey.offloadApps.rawValue: .distantPast])
            .contains(GuideKey.offloadApps.rawValue))
    }

    @Test func checkedProblemsShowEvenWhenMarkedDone() {
        let done = [GuideKey.passcode.rawValue: Date(timeIntervalSince1970: 1_000), GuideKey.updateSystem.rawValue: Date(timeIntervalSince1970: 1_000)]
        #expect(Array(ids(context(upToDate: false, passcode: false), completed: done).prefix(2))
            == [GuideKey.passcode.rawValue, GuideKey.updateSystem.rawValue])
    }

    @Test func recentlyDeletedComesBackAfterNewDeletions() {
        let launch = Date(timeIntervalSince1970: 2_000)
        let doneBefore = [GuideKey.photosRecentlyDeleted.rawValue: Date(timeIntervalSince1970: 1_000)]
        let doneSince = [GuideKey.photosRecentlyDeleted.rawValue: Date(timeIntervalSince1970: 3_000)]
        #expect(ids(context(deletedPhotos: true), completed: doneBefore, sessionStart: launch).first == GuideKey.photosRecentlyDeleted.rawValue)
        #expect(!ids(context(deletedPhotos: true), completed: doneSince, sessionStart: launch).contains(GuideKey.photosRecentlyDeleted.rawValue))
    }

    @Test func eachSuggestionAppearsOnce() {
        let suggested = ids(context(storage: lowStorage, deletedPhotos: true, deletedFiles: true, safari: nil, upToDate: false, passcode: false))
        #expect(Set(suggested).count == suggested.count)
    }

    @Test func remindersSayWhy() {
        let busy = context(storage: lowStorage, deletedPhotos: true, safari: false, upToDate: false, passcode: false, available: "27.0.2")
        #expect(GuideLibrary.reason(for: GuideLibrary.guide(.photosRecentlyDeleted), in: busy) == "Photos you deleted still use space")
        #expect(GuideLibrary.reason(for: GuideLibrary.guide(.updateSystem), in: busy) == "iOS 27.0.2 is available")
        #expect(GuideLibrary.reason(for: GuideLibrary.guide(.passcode), in: busy) == "Your iPhone has no passcode")
        #expect(GuideLibrary.reason(for: GuideLibrary.guide(.safariProtection), in: busy) == "Safari protection is off")
        #expect(GuideLibrary.reason(for: GuideLibrary.guide(.offloadApps), in: busy) == "Your iPhone is almost full")
        #expect(GuideLibrary.reason(for: GuideLibrary.guide(.offloadApps), in: context()) == nil)
        #expect(GuideLibrary.reason(for: GuideLibrary.guide(.lockdownMode), in: busy) == nil)
    }

    @Test func guidesKnowTheirSubjectOnThisDevice() {
        #expect(GuideLibrary.statusNote(for: GuideLibrary.guide(.updateSystem), in: context(upToDate: false, available: "27.0.2"))
            == GuideStatusNote(text: "iOS 27.0.2 is available for your iPhone.", isGood: false))
        #expect(GuideLibrary.statusNote(for: GuideLibrary.guide(.updateSystem), in: context())
            == GuideStatusNote(text: "Your iPhone is up to date (iOS 27.0.1).", isGood: true))
        #expect(GuideLibrary.statusNote(for: GuideLibrary.guide(.safariProtection), in: context(safari: false))?.isGood == false)
        #expect(GuideLibrary.statusNote(for: GuideLibrary.guide(.passcode), in: context(passcode: nil)) == nil)
        #expect(GuideLibrary.statusNote(for: GuideLibrary.guide(.offloadApps), in: context(storage: lowStorage))?.text
            == "Your iPhone is almost full: \(ByteFormatting.string(3_000_000_000)) available.")
    }
}

@MainActor
struct GuideProgressTests {
    @Test func remembersEachGuideSeparately() throws {
        let suite = "GuideProgressTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let progress = GuideProgress(defaults: defaults)
        #expect(!progress.isDone(GuideKey.offloadApps.rawValue))
        progress.setDone(true, for: GuideKey.offloadApps.rawValue)
        #expect(progress.isDone(GuideKey.offloadApps.rawValue))
        #expect(defaults.object(forKey: "guides.done.offload-apps") is Date)

        let reopened = GuideProgress(defaults: defaults)
        #expect(reopened.isDone(GuideKey.offloadApps.rawValue))
        #expect(!reopened.isDone(GuideKey.passcode.rawValue))

        reopened.setDone(false, for: GuideKey.offloadApps.rawValue)
        #expect(GuideProgress(defaults: defaults).completed.isEmpty)
    }
}
