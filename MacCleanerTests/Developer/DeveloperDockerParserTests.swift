import Foundation
import Testing
@testable import MacCleaner

@Suite("Developer – docker output")
struct DeveloperDockerParserTests {
    static let systemDF = """
    {"Active":"2","Reclaimable":"1.234GB (45%)","Size":"2.743GB","TotalCount":"10","Type":"Images"}
    {"Active":"1","Reclaimable":"12.3kB (20%)","Size":"61.5kB","TotalCount":"4","Type":"Containers"}
    {"Active":"1","Reclaimable":"512MB (50%)","Size":"1.024GB","TotalCount":"3","Type":"Local Volumes"}
    {"Active":"0","Reclaimable":"3.5GB","Size":"3.5GB","TotalCount":"42","Type":"Build Cache"}
    """

    @Test func parsesSystemDiskUsageLines() throws {
        let rows = DeveloperDockerParser.parseSystemDF(Self.systemDF)
        #expect(rows.count == 4)

        let images = try #require(rows.first { $0.kind == .images })
        #expect(images.totalCount == 10)
        #expect(images.activeCount == 2)
        #expect(images.sizeBytes == 2_743_000_000)
        #expect(images.reclaimableBytes == 1_234_000_000)
        #expect(images.reclaimablePercent == 45)

        let containers = try #require(rows.first { $0.kind == .containers })
        #expect(containers.inactiveCount == 3)
        #expect(containers.reclaimableBytes == 12_300)

        let volumes = try #require(rows.first { $0.kind == .volumes })
        #expect(volumes.reclaimableBytes == 512_000_000)

        let buildCache = try #require(rows.first { $0.kind == .buildCache })
        #expect(buildCache.reclaimableBytes == 3_500_000_000)
        #expect(buildCache.reclaimablePercent == nil)
    }

    @Test func toleratesNumbersAndNoise() {
        let output = """
        WARNING: something unrelated
        {"Active":0,"Reclaimable":"0B (0%)","Size":"0B","TotalCount":0,"Type":"Images"}

        not json
        """
        let rows = DeveloperDockerParser.parseSystemDF(output)
        #expect(rows.count == 1)
        #expect(rows.first?.sizeBytes == 0)
        #expect(rows.first?.inactiveCount == 0)
    }

    @Test func parsesDockerSizes() {
        #expect(DeveloperDockerParser.parseSize("0B") == 0)
        #expect(DeveloperDockerParser.parseSize("100B") == 100)
        #expect(DeveloperDockerParser.parseSize("12.3kB") == 12_300)
        #expect(DeveloperDockerParser.parseSize("1.5MB") == 1_500_000)
        #expect(DeveloperDockerParser.parseSize("2 GB") == 2_000_000_000)
        #expect(DeveloperDockerParser.parseSize("1TB") == 1_000_000_000_000)
        #expect(DeveloperDockerParser.parseSize("1GiB") == 1_073_741_824)
        #expect(DeveloperDockerParser.parseSize("N/A") == nil)
        #expect(DeveloperDockerParser.parseSize("") == nil)
    }

    @Test func parsesDanglingImages() {
        let output = """
        {"Containers":"N/A","CreatedAt":"2026-09-01 10:00:00 +0200 CEST","CreatedSince":"6 weeks ago","Digest":"\\u003cnone\\u003e","ID":"0123456789ab","Repository":"\\u003cnone\\u003e","SharedSize":"N/A","Size":"812MB","Tag":"\\u003cnone\\u003e","UniqueSize":"N/A","VirtualSize":"812MB"}
        {"Containers":"N/A","ID":"ba9876543210","Repository":"\\u003cnone\\u003e","Size":"1.2GB","Tag":"\\u003cnone\\u003e"}
        """
        let images = DeveloperDockerParser.parseImages(output)
        #expect(images.count == 2)
        #expect(images[0].repository == "<none>")
        #expect(images.compactMap(\.sizeBytes).reduce(0, +) == 2_012_000_000)
    }

    @Test func recognizesAStoppedEngine() {
        let stopped = CommandResult(exitCode: 1, standardOutput: "", standardError: "Cannot connect to the Docker daemon at unix:///Users/me/.docker/run/docker.sock. Is the docker daemon running?", timedOut: false)
        #expect(DeveloperDockerParser.isEngineUnavailable(stopped))
        let other = CommandResult(exitCode: 1, standardOutput: "", standardError: "permission denied while trying to connect", timedOut: false)
        #expect(!DeveloperDockerParser.isEngineUnavailable(other))
    }
}
