import Foundation
import Testing
@testable import MacCleanerMobile

/// What the screens say: counts in the singular and plural, where deleted items go, durations.
struct PhotoWordingTests {
    @Test func deletionReportsSayWhereItemsWentAndHowToFreeTheSpace() {
        let many = PhotoCleanupModel.DeletionReport(count: 34, noun: "photo", size: MediaByteTotal(bytes: 1_200_000_000))
        #expect(many.title == "34 photos moved to Recently Deleted")
        #expect(many.message.hasPrefix("They stay in Photos › "))
        #expect(many.message.hasSuffix("for 30 days. Empty it there to free \(ByteFormatting.string(1_200_000_000)) now."))

        let one = PhotoCleanupModel.DeletionReport(count: 1, noun: "video", size: MediaByteTotal(bytes: 300_000_000, isEstimated: true))
        #expect(one.title == "1 video moved to Recently Deleted")
        #expect(one.message.hasPrefix("It stays"))
        #expect(one.message.contains("about \(ByteFormatting.string(300_000_000))"))
    }

    @Test func recentlyDeletedIsWhereThisVersionOfPhotosKeepsIt() {
        #expect(PhotosRecentlyDeleted.location(systemMajorVersion: 17) == "Photos › Albums › Recently Deleted")
        #expect(PhotosRecentlyDeleted.location(systemMajorVersion: 18) == "Photos › Utilities › Recently Deleted")
        #expect(PhotosRecentlyDeleted.location(systemMajorVersion: 26) == "Photos › Collections › Utilities › Recently Deleted")
        #expect(PhotosRecentlyDeleted.location(systemMajorVersion: 27) == PhotosRecentlyDeleted.location(systemMajorVersion: 26))
    }

    @Test func categoryLinesUseTheSingularForOne() {
        #expect(PhotoCategory.duplicates.detailText(candidates: 1, groups: 1) == "1 extra copy in 1 set")
        #expect(PhotoCategory.duplicates.detailText(candidates: 7, groups: 5) == "7 extra copies in 5 sets")
        #expect(PhotoCategory.bursts.detailText(candidates: 12, groups: 1) == "12 extra frames in 1 burst")
        #expect(PhotoCategory.screenshots.detailText(candidates: 1, groups: 0) == "1 screenshot")
        #expect(PhotoCategory.similar.countText(1_204) == "1,204 similar photos")
        #expect(PhotoCategory.largeVideos.countText(1) == "1 large video")
    }

    @Test func progressReadsLikeASentence() {
        let progress = PhotoScanProgress(stage: .comparing, completed: 1_234, total: 5_678)
        #expect(progress.message == "1,234 of 5,678 photos compared")
        #expect((progress.fraction ?? 0) > PhotoScanProgress(stage: .comparing, completed: 1, total: 5_678).fraction ?? 1)
        #expect(PhotoScanProgress(stage: .reading).fraction == nil)
    }

    @Test func durationsLookLikeTheClockInPhotos() {
        #expect(MediaDescription.duration(42) == "0:42")
        #expect(MediaDescription.duration(65.4) == "1:05")
        #expect(MediaDescription.duration(3_909) == "1:05:09")
    }

    @Test func screenshotsAreGroupedByMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let october = Date(timeIntervalSince1970: 1_760_000_000)
        let items = [
            PhotoFixtures.screenshot("late october", minutes: 60),
            PhotoFixtures.screenshot("october", minutes: 0),
            PhotoFixtures.screenshot("september", minutes: -60 * 24 * 30),
        ].map { item -> MediaItem in
            var item = item
            item.creationDate = item.creationDate.map { october.addingTimeInterval($0.timeIntervalSince(PhotoFixtures.start)) }
            return item
        }
        let sections = MediaMonthSection.sections(of: items.sorted(by: MediaItem.newestFirst), calendar: calendar)
        #expect(sections.map { $0.items.map(\.id) } == [["late october", "october"], ["september"]])
    }
}
