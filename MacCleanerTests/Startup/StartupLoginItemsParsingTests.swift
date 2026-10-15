import Foundation
import Testing
@testable import MacCleaner

struct StartupLoginItemsParsingTests {
    /// Builds the `{names, paths, hidden flags}` list System Events returns, without asking System Events.
    private func descriptor(names: [String], paths: [NSAppleEventDescriptor], hidden: [Bool]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        let nameList = NSAppleEventDescriptor.list()
        for name in names { nameList.insert(NSAppleEventDescriptor(string: name), at: 0) }
        let pathList = NSAppleEventDescriptor.list()
        for path in paths { pathList.insert(path, at: 0) }
        let hiddenList = NSAppleEventDescriptor.list()
        for flag in hidden { hiddenList.insert(NSAppleEventDescriptor(boolean: flag), at: 0) }
        list.insert(nameList, at: 0)
        list.insert(pathList, at: 0)
        list.insert(hiddenList, at: 0)
        return list
    }

    @Test func parsesNamesPathsAndHiddenFlags() throws {
        let result = descriptor(
            names: ["Dropbox", "Rectangle"],
            paths: [NSAppleEventDescriptor(string: "/Applications/Dropbox.app"), NSAppleEventDescriptor(string: "/Applications/Rectangle.app/")],
            hidden: [true, false]
        )
        let records = try #require(StartupLoginItemsService.parse(result))
        #expect(records == [
            StartupLoginItemRecord(name: "Dropbox", path: "/Applications/Dropbox.app", hidden: true),
            StartupLoginItemRecord(name: "Rectangle", path: "/Applications/Rectangle.app", hidden: false),
        ])
    }

    @Test func missingValuePathBecomesNil() throws {
        let missingValue = NSAppleEventDescriptor(typeCode: 0x6D73_6E67) // 'msng'
        let result = descriptor(names: ["Old App"], paths: [missingValue], hidden: [false])
        let records = try #require(StartupLoginItemsService.parse(result))
        #expect(records.count == 1)
        #expect(records[0].path == nil)
    }

    @Test func noLoginItemsGivesAnEmptyList() throws {
        let result = descriptor(names: [], paths: [], hidden: [])
        let records = try #require(StartupLoginItemsService.parse(result))
        #expect(records.isEmpty)
    }

    @Test func unexpectedShapesAreRejected() {
        #expect(StartupLoginItemsService.parse(NSAppleEventDescriptor(string: "nope")) == nil)
        let twoLists = NSAppleEventDescriptor.list()
        twoLists.insert(NSAppleEventDescriptor.list(), at: 0)
        twoLists.insert(NSAppleEventDescriptor.list(), at: 0)
        #expect(StartupLoginItemsService.parse(twoLists) == nil)
    }

    @Test func appleScriptStringsAreEscaped() {
        #expect(StartupLoginItemsService.appleScriptEscaped("Plain") == "Plain")
        #expect(StartupLoginItemsService.appleScriptEscaped("Say \"Hi\"") == "Say \\\"Hi\\\"")
        #expect(StartupLoginItemsService.appleScriptEscaped("Back\\slash") == "Back\\\\slash")
    }
}
