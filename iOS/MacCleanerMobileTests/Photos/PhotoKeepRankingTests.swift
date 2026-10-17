import Foundation
import Testing
@testable import MacCleanerMobile

/// Which photo of a set stays: a favorite, then an edited one, more pixels, a larger file, the older one.
struct PhotoKeepRankingTests {
    typealias Fixture = PhotoFixtures

    @Test func aFavoriteWinsOverEverythingElse() {
        let favorite = Fixture.photo("favorite", width: 1200, height: 900, minutes: 10, hash: 1, bytes: 400_000, favorite: true)
        let edited = Fixture.photo("edited", hash: 1, bytes: 5_000_000, edited: true)
        #expect(PhotoKeepRanking.best(of: [edited, favorite])?.id == "favorite")
    }

    @Test func anEditedPhotoWinsOverMorePixels() {
        let edited = Fixture.photo("edited", width: 2000, height: 1500, minutes: 10, hash: 1, bytes: 1_000_000, edited: true)
        let sharper = Fixture.photo("sharper", hash: 1, bytes: 5_000_000)
        #expect(PhotoKeepRanking.best(of: [sharper, edited])?.id == "edited")
    }

    @Test func morePixelsWinOverALargerFile() {
        let sharper = Fixture.photo("sharper", minutes: 10, hash: 1, bytes: 2_000_000)
        let heavier = Fixture.photo("heavier", width: 2016, height: 1512, hash: 1, bytes: 6_000_000)
        #expect(PhotoKeepRanking.best(of: [heavier, sharper])?.id == "sharper")
    }

    @Test func aLargerFileWinsOverAnOlderOne() {
        let larger = Fixture.photo("larger", minutes: 10, hash: 1, bytes: 3_000_000)
        let older = Fixture.photo("older", hash: 1, bytes: 1_000_000)
        #expect(PhotoKeepRanking.best(of: [older, larger])?.id == "larger")
    }

    @Test func theOlderOneWinsWhenAllElseIsEqual() {
        let original = Fixture.photo("original", minutes: 0, hash: 1)
        let copy = Fixture.photo("copy", minutes: 5, hash: 1)
        #expect(PhotoKeepRanking.best(of: [copy, original])?.id == "original")
        var undated = Fixture.photo("undated", hash: 1)
        undated.creationDate = nil
        #expect(PhotoKeepRanking.best(of: [undated, copy])?.id == "copy")
    }

    @Test func theOrderNeverDependsOnTheInput() {
        let twins = (0..<5).map { Fixture.photo("twin \($0)", hash: 1) }
        let ranked = PhotoKeepRanking.ranked(twins).map(\.id)
        #expect(ranked == ["twin 0", "twin 1", "twin 2", "twin 3", "twin 4"])
        #expect(PhotoKeepRanking.ranked(twins.reversed()).map(\.id) == ranked)
        #expect(PhotoKeepRanking.ranked(twins.shuffled()).map(\.id) == ranked)
    }

    @Test func aSetShowsTheKeptPhotoFirst() {
        let set = MediaGroup(lookalikes: [
            Fixture.photo("late copy", minutes: 20, hash: 1),
            Fixture.photo("early copy", minutes: 10, hash: 1),
            Fixture.photo("edited", minutes: 30, hash: 1, edited: true),
        ])
        #expect(set.keeperIDs == ["edited"])
        #expect(set.items.map(\.id) == ["edited", "early copy", "late copy"])
        #expect(set.extras.map(\.id) == ["early copy", "late copy"])
    }
}
