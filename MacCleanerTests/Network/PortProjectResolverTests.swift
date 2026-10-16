import Foundation
import Testing
@testable import MacCleaner

/// In-memory file tree for resolver tests. Adding a file implicitly creates its parent directories.
/// Build the tree before handing it to a resolver; probes may then run on the resolver's probe queues.
final class PortResolverTestFS: @unchecked Sendable {
    private(set) var directories: Set<String> = ["/"]
    private(set) var files: [String: Data] = [:]
    private let lock = NSLock()
    private var probes = 0
    /// Probes under this prefix wait until `releaseBlockedProbes()`, like a pending macOS folder-access prompt.
    private var blockedPrefix: String?
    private var isBlocked = false
    private let gate = DispatchGroup()

    /// Paths probed through `fileExists`, to check caching.
    var probeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return probes
    }

    func addFile(_ path: String, _ contents: String = "") {
        files[path] = Data(contents.utf8)
        addDirectory(PortProjectResolver.parent(of: path))
    }

    func addDirectory(_ path: String) {
        var current = path
        while current != "/", !directories.contains(current) {
            directories.insert(current)
            current = PortProjectResolver.parent(of: current)
        }
    }

    /// Makes every probe under `prefix` block until `releaseBlockedProbes()`. Call before using a resolver.
    func blockProbes(under prefix: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !isBlocked else { return }
        blockedPrefix = prefix
        isBlocked = true
        gate.enter()
    }

    /// Lets blocked probes continue. Safe to call more than once.
    func releaseBlockedProbes() {
        lock.lock()
        defer { lock.unlock() }
        guard isBlocked else { return }
        isBlocked = false
        gate.leave()
    }

    private func waitIfBlocked(_ path: String) {
        lock.lock()
        let blocks = isBlocked && blockedPrefix.map { path.hasPrefix($0) } == true
        lock.unlock()
        if blocks { gate.wait() }
    }

    func fileExists(_ path: String) -> Bool {
        waitIfBlocked(path)
        lock.lock()
        probes += 1
        lock.unlock()
        return files[path] != nil || directories.contains(path)
    }

    func readFile(_ path: String) -> Data? {
        waitIfBlocked(path)
        return files[path]
    }

    func listDirectory(_ path: String) -> [String]? {
        waitIfBlocked(path)
        guard directories.contains(path) else { return nil }
        let prefix = path == "/" ? "/" : path + "/"
        var names = Set<String>()
        for entry in Array(files.keys) + Array(directories) where entry.hasPrefix(prefix) && entry != path {
            if let name = entry.dropFirst(prefix.count).split(separator: "/").first { names.insert(String(name)) }
        }
        return names.sorted()
    }

    /// A resolver over this tree. The generous default deadline keeps answers final on a busy machine; the
    /// deadline tests pass a short one.
    func makeResolver(home: String = PortResolverTestFS.home, now: @escaping @Sendable () -> Date = { Date() },
                      probeDeadline: TimeInterval = 10) -> PortProjectResolver {
        PortProjectResolver(homeDirectory: home,
                        fileExists: { [unowned self] in self.fileExists($0) },
                        readFile: { [unowned self] in self.readFile($0) },
                        listDirectory: { [unowned self] in self.listDirectory($0) },
                        now: now,
                        probeDeadline: probeDeadline)
    }

    static let home = "/Users/test"
}

/// Builds PortProcessDetails fixtures.
enum PortResolverTestProcess {
    static func details(pid: Int32 = 100, executable: String?, arguments: [String], cwd: String?,
                        environment: [String: String] = [:]) -> PortProcessDetails {
        PortProcessDetails(identity: PortProcessIdentity(pid: pid, startTime: 1), executablePath: executable,
                       arguments: arguments, environment: environment, cwd: cwd)
    }
}

@Suite struct PortProjectResolverTests {
    private let home = PortResolverTestFS.home

    // MARK: Grouping roots

    @Test func gitRootGroupsSiblingPackagesUnderRootFolderName() {
        let fs = PortResolverTestFS()
        let root = home + "/Downloads/Harbor Notes"
        fs.addDirectory(root + "/.git")
        fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"harbor-api\"\n")
        fs.addFile(root + "/frontend/package.json", #"{"name": "harbor-web"}"#)
        let resolver = fs.makeResolver()

        let backend = resolver.project(forDirectory: root + "/backend")
        let frontend = resolver.project(forDirectory: root + "/frontend")
        #expect(backend?.rootPath == root)
        #expect(frontend?.rootPath == root)
        #expect(backend?.name == "Harbor Notes")
        #expect(backend?.subpath == "backend")
        #expect(frontend?.subpath == "frontend")
        #expect(backend?.markers == [".git", "pyproject.toml"])
    }

    @Test func siblingManifestRuleWithoutGit() {
        let fs = PortResolverTestFS()
        let root = home + "/Downloads/Harbor Notes"
        fs.addFile(root + "/backend/pyproject.toml", "[project]\nname = \"harbor-api\"\n")
        fs.addFile(root + "/frontend/package.json", #"{"name": "harbor-web"}"#)
        let resolver = fs.makeResolver()

        let backend = resolver.project(forDirectory: root + "/backend")
        let frontend = resolver.project(forDirectory: root + "/frontend/src")
        #expect(backend?.rootPath == root)
        #expect(frontend?.rootPath == root)
        #expect(backend?.name == "Harbor Notes")
        #expect(frontend?.subpath == "frontend")
    }

    @Test func genericRootFolderIsPrefixedWithParent() {
        let fs = PortResolverTestFS()
        let release = home + "/.codex/acme-public-deployment-20261008/release"
        fs.addFile(release + "/README.md")
        fs.addFile(release + "/backend/pyproject.toml", "[project]\nname = \"acme-api\"\n")
        fs.addFile(release + "/frontend/package.json", #"{"name": "acme-web"}"#)
        let info = fs.makeResolver().project(forDirectory: release + "/backend")

        #expect(info?.rootPath == release)
        #expect(info?.name == "acme-public-deployment-20261008/release")
        #expect(info?.subpath == "backend")
        #expect(info?.markers == ["pyproject.toml"])
    }

    @Test func rootWrappingSinglePackageTakesPackageName() {
        let fs = PortResolverTestFS()
        let wrapper = home + "/Downloads/uptime check"
        fs.addDirectory(wrapper + "/.git")
        fs.addFile(wrapper + "/uptime-monitor/package.json", #"{"name": "uptime-monitor", "private": true}"#)
        let info = fs.makeResolver().project(forDirectory: wrapper + "/uptime-monitor")

        #expect(info?.rootPath == wrapper)
        #expect(info?.name == "uptime-monitor")
        #expect(info?.subpath == "uptime-monitor")
    }

    @Test func wrappedGenericPartKeepsRepositoryName() {
        let fs = PortResolverTestFS()
        let repo = home + "/code/shop"
        fs.addDirectory(repo + "/.git")
        fs.addFile(repo + "/backend/pyproject.toml", "[project]\nname = \"shop-api\"\n")
        #expect(fs.makeResolver().project(forDirectory: repo + "/backend")?.name == "shop")
    }

    @Test func unrelatedProjectsInPlainFolderStaySeparate() {
        let fs = PortResolverTestFS()
        let container = home + "/Downloads/hacks"
        fs.addFile(container + "/PortPilot/Package.swift")
        fs.addFile(container + "/dashboard-kit/package.json", #"{"name": "dashboard-kit"}"#)
        let resolver = fs.makeResolver()

        #expect(resolver.project(forDirectory: container + "/PortPilot")?.rootPath == container + "/PortPilot")
        #expect(resolver.project(forDirectory: container + "/dashboard-kit")?.name == "dashboard-kit")
    }

    @Test func readmeOnlyParentKeepsDistinctToolsSeparate() {
        let fs = PortResolverTestFS()
        let shop = home + "/Downloads/shop"
        fs.addFile(shop + "/README.md", "# my tools")
        fs.addFile(shop + "/.gitignore")
        fs.addFile(shop + "/.editorconfig")
        fs.addFile(shop + "/shop-api/requirements.txt")
        fs.addFile(shop + "/shop-web/package.json", #"{"name": "shop-web"}"#)
        let resolver = fs.makeResolver()

        let api = resolver.project(forDirectory: shop + "/shop-api")
        #expect(api?.rootPath == shop + "/shop-api", "a README is no reason to merge distinct tools")
        #expect(api?.subpath == nil)
        #expect(resolver.project(forDirectory: shop + "/shop-web")?.rootPath == shop + "/shop-web")
        #expect(resolver.project(forDirectory: shop + "/shop-web")?.name == "shop-web")
    }

    @Test func distinctSingleSubprojectIsItsOwnRoot() {
        let fs = PortResolverTestFS()
        let folder = home + "/Downloads/Pixelpost"
        fs.addFile(folder + "/sunbeam-backend/requirements.txt")
        fs.addFile(folder + "/sunbeam-backend/app.py")
        fs.addFile(folder + "/Sunbeam/project.yml")
        let info = fs.makeResolver().project(forDirectory: folder + "/sunbeam-backend")
        #expect(info?.rootPath == folder + "/sunbeam-backend")
        #expect(info?.name == "sunbeam-backend")
        #expect(info?.subpath == nil)
    }

    @Test func workspaceRootWithoutGit() {
        let fs = PortResolverTestFS()
        let mono = home + "/code/mono"
        fs.addFile(mono + "/package.json", #"{"name": "mono", "workspaces": ["packages/*"]}"#)
        fs.addFile(mono + "/packages/web/package.json", #"{"name": "@mono/web"}"#)
        let info = fs.makeResolver().project(forDirectory: mono + "/packages/web")
        #expect(info?.rootPath == mono)
        #expect(info?.name == "mono")
        #expect(info?.subpath == "packages/web")
    }

    // MARK: Names

    @Test func manifestNames() {
        let fs = PortResolverTestFS()
        fs.addFile(home + "/code/a/package.json", #"{"name": "storefront"}"#)
        fs.addFile(home + "/code/b/package.json", #"{"name": "@acme/web"}"#)
        fs.addFile(home + "/code/c/package.json", #"{"name": "vite-project"}"#)
        fs.addFile(home + "/code/d/pyproject.toml", "[build-system]\nrequires = []\n\n[tool.poetry]\nname = 'poetry-app'\n")
        fs.addFile(home + "/code/e/Cargo.toml", "[package]\nname = \"rusty\"\nversion = \"0.1.0\"\n")
        fs.addFile(home + "/code/f/Cargo.toml", "[workspace]\nmembers = [\"x\"]\n")
        fs.addFile(home + "/code/g/pyproject.toml", "[tool.black]\nnamespace = 'x'\n[project]\nname = \"api\"\n")
        let resolver = fs.makeResolver()

        #expect(resolver.project(forDirectory: home + "/code/a")?.name == "storefront")
        #expect(resolver.project(forDirectory: home + "/code/b")?.name == "b", "scoped names keep the folder name")
        #expect(resolver.project(forDirectory: home + "/code/c")?.name == "c", "template defaults are generic")
        #expect(resolver.project(forDirectory: home + "/code/d")?.name == "poetry-app")
        #expect(resolver.project(forDirectory: home + "/code/e")?.name == "rusty")
        #expect(resolver.project(forDirectory: home + "/code/f")?.name == "f")
        #expect(resolver.project(forDirectory: home + "/code/g")?.name == "g", "generic manifest names are ignored")
    }

    @Test func truncatedPackageJSONStillYieldsName() {
        let fs = PortResolverTestFS()
        let padding = String(repeating: "x", count: 300 * 1024)
        fs.addFile(home + "/code/big/package.json", "{\n  \"name\" : \"big-app\",\n  \"blob\": \"\(padding)\"\n}")
        #expect(fs.makeResolver().project(forDirectory: home + "/code/big")?.name == "big-app")
    }

    @Test func tomlNameParser() {
        let toml = Data("[tool.poetry]\nname=\"spaced\"\n".utf8)
        #expect(PortProjectResolver.tomlName(toml, tables: ["tool.poetry"]) == "spaced")
        #expect(PortProjectResolver.tomlName(toml, tables: ["project"]) == nil)
    }

    // MARK: Exclusions

    @Test func homeAndContainerRootsAreNeverProjects() {
        let fs = PortResolverTestFS()
        fs.addFile(home + "/package.json", #"{"name": "dotfiles"}"#)
        fs.addFile(home + "/Downloads/package.json", #"{"name": "stray"}"#)
        fs.addDirectory(home + "/Desktop")
        fs.addDirectory(home + "/Documents")
        let resolver = fs.makeResolver()

        #expect(resolver.project(forDirectory: home) == nil)
        #expect(resolver.project(forDirectory: home + "/") == nil)
        #expect(resolver.project(forDirectory: home + "/Downloads") == nil)
        #expect(resolver.project(forDirectory: home + "/Desktop") == nil)
        #expect(resolver.project(forDirectory: home + "/Documents") == nil)
        #expect(resolver.project(forDirectory: "/") == nil)
    }

    @Test func dotfilesRepositoryInHomeIsIgnored() {
        let fs = PortResolverTestFS()
        fs.addDirectory(home + "/.git")
        fs.addFile(home + "/Downloads/notes/serve.py")
        let info = fs.makeResolver().project(forDirectory: home + "/Downloads/notes")
        #expect(info?.rootPath == home + "/Downloads/notes")
        #expect(info?.markers == [])
    }

    @Test func toolCachesLibraryAndSystemLocationsAreExcluded() {
        let fs = PortResolverTestFS()
        fs.addFile(home + "/.npm/_npx/abc123/package.json", #"{"name": "mcp"}"#)
        fs.addFile(home + "/Library/Application Support/uptime-monitor/package.json")
        fs.addFile(home + "/.vscode/extensions/ext/package.json")
        fs.addFile("/opt/homebrew/var/postgresql@16/postgresql.conf")
        fs.addFile("/Applications/Tool.app/Contents/Resources/app/package.json")
        let resolver = fs.makeResolver()

        #expect(resolver.project(forDirectory: home + "/.npm/_npx/abc123") == nil)
        #expect(resolver.project(forDirectory: home + "/Library/Application Support/uptime-monitor") == nil)
        #expect(resolver.project(forDirectory: home + "/.vscode/extensions/ext") == nil)
        #expect(resolver.project(forDirectory: "/opt/homebrew/var/postgresql@16") == nil)
        #expect(resolver.project(forDirectory: "/Applications/Tool.app/Contents/Resources/app") == nil)
        #expect(resolver.project(forDirectory: "/usr/local/lib") == nil)
    }

    @Test func codeDirectoriesOutsideHomeNeedMarkers() {
        let fs = PortResolverTestFS()
        fs.addFile("/opt/myapp/package.json", #"{"name": "myapp"}"#)
        fs.addDirectory("/opt/empty")
        fs.addDirectory("/Volumes/SSD/code/tool/.git")
        fs.addFile(home + "/Library/Mobile Documents/com~apple~CloudDocs/site/index.html")
        let resolver = fs.makeResolver()

        #expect(resolver.project(forDirectory: "/opt/myapp/src")?.rootPath == "/opt/myapp")
        #expect(resolver.project(forDirectory: "/opt/empty") == nil)
        #expect(resolver.project(forDirectory: "/Volumes/SSD/code/tool")?.name == "tool")
        #expect(resolver.project(forDirectory: home + "/Library/Mobile Documents/com~apple~CloudDocs/site")?.name == "site", "iCloud Drive folders behave like home folders")
    }

    // MARK: resolve(details:)

    @Test func resolveUsesCwdFirst() {
        let fs = PortResolverTestFS()
        fs.addFile(home + "/Downloads/uptime check/uptime-monitor/package.json", #"{"name": "uptime-monitor"}"#)
        let details = PortResolverTestProcess.details(
            executable: "/opt/homebrew/bin/node",
            arguments: ["/opt/homebrew/bin/node", home + "/Downloads/uptime check/uptime-monitor/server.js"],
            cwd: home + "/Downloads/uptime check/uptime-monitor")
        #expect(fs.makeResolver().resolve(details: details)?.name == "uptime-monitor")
    }

    @Test func resolveFallsBackToScriptPathAndStripsNodeModules() {
        let fs = PortResolverTestFS()
        let app = home + "/code/app"
        fs.addDirectory(app + "/.git")
        fs.addFile(app + "/frontend/package.json", #"{"name": "app-frontend"}"#)
        fs.addFile(app + "/frontend/node_modules/vite/package.json", #"{"name": "vite"}"#)
        fs.addFile(app + "/frontend/node_modules/vite/bin/vite.js")
        let details = PortResolverTestProcess.details(
            executable: "/opt/homebrew/bin/node",
            arguments: ["node", app + "/frontend/node_modules/vite/bin/vite.js", "--port", "5173"], cwd: "/")
        let info = fs.makeResolver().resolve(details: details)
        #expect(info?.rootPath == app)
        #expect(info?.subpath == "frontend")
    }

    @Test func resolveSkipsMissingAndExcludedArguments() {
        let fs = PortResolverTestFS()
        fs.addFile(home + "/Library/Application Support/tunnel/config.yml")
        let details = PortResolverTestProcess.details(
            executable: "/opt/homebrew/bin/cloudflared",
            arguments: ["cloudflared", "tunnel", "--config", home + "/Library/Application Support/tunnel/config.yml"],
            cwd: home + "/Library/Application Support/tunnel")
        #expect(fs.makeResolver().resolve(details: details) == nil)
    }

    @Test func markerlessFolderCountsOnlyForRuntimes() {
        let fs = PortResolverTestFS()
        fs.addDirectory(home + "/Downloads/Pixelpost/.claude")
        fs.addFile(home + "/Downloads/photos/index.html")
        let resolver = fs.makeResolver()

        let mcp = PortResolverTestProcess.details(executable: home + "/.local/bin/codebase-memory-mcp",
                                              arguments: [home + "/.local/bin/codebase-memory-mcp"],
                                              cwd: home + "/Downloads/Pixelpost")
        #expect(resolver.resolve(details: mcp) == nil, "a native tool that inherited a cwd is not a project")

        let server = PortResolverTestProcess.details(executable: "/usr/bin/python3",
                                                 arguments: ["python3", "-m", "http.server", "8000"],
                                                 cwd: home + "/Downloads/photos")
        let info = resolver.resolve(details: server)
        #expect(info?.name == "photos")
        #expect(info?.markers == [])
    }

    @Test func resolveUsesExecutableInsideProject() {
        let fs = PortResolverTestFS()
        fs.addFile(home + "/code/svc/Cargo.toml", "[package]\nname = \"svc\"\n")
        fs.addFile(home + "/code/svc/target/debug/server")
        let details = PortResolverTestProcess.details(executable: home + "/code/svc/target/debug/server",
                                                  arguments: ["./target/debug/server"], cwd: "/")
        let info = fs.makeResolver().resolve(details: details)
        #expect(info?.rootPath == home + "/code/svc")
        #expect(info?.name == "svc")
    }

    @Test func resolveUsesVirtualEnvironment() {
        let fs = PortResolverTestFS()
        fs.addFile(home + "/code/api/requirements.txt")
        let details = PortResolverTestProcess.details(
            executable: "/opt/homebrew/Cellar/python@3.12/3.12.1/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python",
            arguments: ["python", "-m", "uvicorn", "main:app"], cwd: "/",
            environment: ["VIRTUAL_ENV": home + "/code/api/.venv"])
        #expect(fs.makeResolver().resolve(details: details)?.rootPath == home + "/code/api")
    }

    @Test func gUIApplicationsNeverGetAProject() {
        let fs = PortResolverTestFS()
        fs.addDirectory(home + "/code/site/.git")
        let helper = PortResolverTestProcess.details(
            executable: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
            arguments: ["Code Helper (Plugin)", "--type=utility"], cwd: home + "/code/site")
        #expect(fs.makeResolver().resolve(details: helper) == nil)

        let electronDev = PortResolverTestProcess.details(
            executable: home + "/code/site/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron",
            arguments: ["Electron", "."], cwd: home + "/code/site")
        #expect(fs.makeResolver().resolve(details: electronDev)?.name == "site", "Electron apps under development belong to their project")
    }

    @Test func nilDetailsAndRootCwd() {
        let fs = PortResolverTestFS()
        let resolver = fs.makeResolver()
        #expect(resolver.resolve(details: nil) == nil)
        let details = PortResolverTestProcess.details(executable: "/usr/libexec/rapportd", arguments: ["rapportd"], cwd: "/")
        #expect(resolver.resolve(details: details) == nil)
    }

    // MARK: Caching

    @Test func directoryLookupsAreCachedForSixtySeconds() {
        let fs = PortResolverTestFS()
        let clock = PortTestClock(Date(timeIntervalSince1970: 1_000))
        let resolver = fs.makeResolver(now: { clock.now })
        let folder = home + "/code/late"
        fs.addFile(folder + "/requirements.txt")

        #expect(resolver.project(forDirectory: folder)?.markers == ["requirements.txt"])
        let probes = fs.probeCount
        fs.addDirectory(folder + "/.git")

        clock.advance(30)
        #expect(resolver.project(forDirectory: folder)?.markers == ["requirements.txt"])
        #expect(fs.probeCount == probes, "cached lookups must not touch the file system")

        clock.advance(31)
        #expect(resolver.project(forDirectory: folder)?.markers == [".git", "requirements.txt"])
    }

    @Test func concurrentLookupsAreSafe() {
        let resolver = PortProjectResolver(homeDirectory: home, fileExists: { $0.hasSuffix("/code/x/package.json") },
                                       readFile: { _ in Data(#"{"name": "x"}"#.utf8) })
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let info = resolver.project(forDirectory: home + "/code/x/sub\(index % 7)")
            #expect(info?.name == "x")
        }
    }

    // MARK: Path helpers

    @Test func pathHelpers() {
        #expect(PortProjectResolver.normalize("/a//b/./c/../d/") == "/a/b/d")
        #expect(PortProjectResolver.normalize("") == "/")
        #expect(PortProjectResolver.parent(of: "/a") == "/")
        #expect(PortProjectResolver.strippingDependencyFolders("/u/p/node_modules/.pnpm/vite@5/node_modules/vite/bin") == "/u/p")
        #expect(PortProjectResolver.strippingDependencyFolders("/u/p/.venv/bin") == "/u/p")
        #expect(PortProjectResolver.strippingDependencyFolders("/u/p/env/bin") == "/u/p")
        #expect(PortProjectResolver.strippingDependencyFolders("/u/p/env/config") == "/u/p/env/config")
    }
}

/// Grouping without git: only real evidence (declared workspaces, compose files, generic parts) merges folders.
@Suite struct PortProjectResolverGroupingTests {
    private let home = PortResolverTestFS.home

    private func node(cwd: String) -> PortProcessDetails {
        PortResolverTestProcess.details(executable: "/opt/homebrew/bin/node", arguments: ["node", "server.js"], cwd: cwd)
    }

    private func python(cwd: String) -> PortProcessDetails {
        PortResolverTestProcess.details(executable: "/usr/bin/python3", arguments: ["python3", "-m", "http.server"],
                                    cwd: cwd)
    }

    @Test func strayPackageJSONParentKeepsToolsSeparate() {
        let fs = PortResolverTestFS()
        let tools = home + "/Downloads/odds-and-ends"
        fs.addFile(tools + "/package.json", #"{"dependencies": {"left-pad": "^1.3.0"}}"#)
        fs.addFile(tools + "/porttool/package.json", #"{"name": "porttool"}"#)
        fs.addFile(tools + "/bunthing/bun.lockb")
        fs.addFile(tools + "/gosvc/go.mod", "module gosvc\n")
        fs.addFile(tools + "/looptool/pyproject.toml", "[project]\nname = \"looptool\"\n")
        fs.addFile(tools + "/loose/serve.py")
        fs.addFile(tools + "/loose/public/index.html")
        let resolver = fs.makeResolver()

        #expect(resolver.resolve(details: node(cwd: tools + "/porttool"))?.rootPath == tools + "/porttool")
        #expect(resolver.resolve(details: node(cwd: tools + "/porttool"))?.name == "porttool")
        #expect(resolver.resolve(details: node(cwd: tools + "/bunthing"))?.rootPath == tools + "/bunthing")
        #expect(resolver.project(forDirectory: tools + "/gosvc")?.rootPath == tools + "/gosvc")
        #expect(resolver.resolve(details: python(cwd: tools + "/looptool"))?.name == "looptool")

        let loose = resolver.resolve(details: python(cwd: tools + "/loose"))
        #expect(loose?.rootPath == tools + "/loose", "a marker-less tool does not adopt a stray package.json")
        #expect(loose?.name == "loose")
        #expect(loose?.markers == [])
        #expect(resolver.resolve(details: python(cwd: tools + "/loose/public"))?.rootPath == tools + "/loose", "sub-folders of a loose tool stay with that tool")
        #expect(resolver.resolve(details: PortResolverTestProcess.details(
            executable: home + "/.local/bin/mcp-tool", arguments: ["mcp-tool"], cwd: tools + "/loose")) == nil, "a native tool that inherited the cwd still has no project")
    }

    @Test func namedParentProjectDoesNotAbsorbDistinctChildren() {
        let fs = PortResolverTestFS()
        let parent = home + "/Downloads/umbrella"
        fs.addFile(parent + "/package.json", #"{"name": "umbrella", "scripts": {"dev": "vite"}}"#)
        fs.addFile(parent + "/porttool/package.json", #"{"name": "porttool"}"#)
        fs.addFile(parent + "/api/package.json", #"{"name": "umbrella-api"}"#)
        fs.addFile(parent + "/side-script/run.py")
        let resolver = fs.makeResolver()

        #expect(resolver.project(forDirectory: parent + "/porttool")?.rootPath == parent + "/porttool")
        let api = resolver.project(forDirectory: parent + "/api")
        #expect(api?.rootPath == parent, "generic parts still join the project around them")
        #expect(api?.subpath == "api")
        #expect(api?.name == "umbrella")
        #expect(resolver.resolve(details: python(cwd: parent + "/side-script"))?.rootPath == parent + "/side-script", "a folder that holds other projects is a container")
    }

    @Test func markerlessFoldersInsideAProjectStillBelongToIt() {
        let fs = PortResolverTestFS()
        let app = home + "/Downloads/myapp"
        fs.addFile(app + "/package.json", #"{"name": "myapp"}"#)
        fs.addFile(app + "/src/server.js")
        fs.addFile(app + "/tooling-x/gen.py")
        fs.addFile(app + "/.build/debug/server")
        let resolver = fs.makeResolver()

        #expect(resolver.resolve(details: node(cwd: app + "/src"))?.rootPath == app)
        #expect(resolver.resolve(details: python(cwd: app + "/tooling-x"))?.rootPath == app, "a lone project keeps its distinctly named sub-folders")
        let binary = PortResolverTestProcess.details(executable: app + "/.build/debug/server",
                                                 arguments: ["./.build/debug/server"], cwd: "/")
        #expect(resolver.resolve(details: binary)?.rootPath == app)
        #expect(resolver.resolve(details: binary)?.name == "myapp")
    }

    @Test func declaredWorkspacesGroupTheirPackages() {
        let fs = PortResolverTestFS()
        let code = home + "/code"
        fs.addFile(code + "/pn/package.json", #"{"name": "pn"}"#)
        fs.addFile(code + "/pn/pnpm-workspace.yaml", "packages:\n  - 'packages/*'\n")
        fs.addFile(code + "/pn/packages/ui-kit/package.json", #"{"name": "ui-kit"}"#)
        fs.addFile(code + "/rs/Cargo.toml", "[workspace]\nmembers = [\"crates/*\"]\n")
        fs.addFile(code + "/rs/crates/parser/Cargo.toml", "[package]\nname = \"parser\"\n")
        fs.addFile(code + "/gw/go.work", "go 1.22\nuse ./svc-a\n")
        fs.addFile(code + "/gw/svc-a/go.mod", "module svc-a\n")
        fs.addFile(code + "/gr/settings.gradle.kts", "rootProject.name = \"gr\"\ninclude(\":app-core\")\n")
        fs.addFile(code + "/gr/build.gradle.kts")
        fs.addFile(code + "/gr/app-core/build.gradle.kts")
        fs.addFile(code + "/uv/pyproject.toml", "[project]\nname = \"uvroot\"\n[tool.uv.workspace]\nmembers = [\"pkgs/*\"]\n")
        fs.addFile(code + "/uv/pkgs/etl/pyproject.toml", "[project]\nname = \"etl\"\n")
        fs.addFile(code + "/mvn/pom.xml", "<project><modules><module>billing</module></modules></project>")
        fs.addFile(code + "/mvn/billing/pom.xml", "<project/>")
        fs.addFile(code + "/tb/package.json", #"{"name": "tb", "workspaces": {"packages": ["apps/*"]}}"#)
        fs.addFile(code + "/tb/apps/storefront/package.json", #"{"name": "storefront"}"#)
        fs.addFile(code + "/tb/apps/storefront/e2e-suite/package.json", #"{"name": "storefront-e2e"}"#)
        let resolver = fs.makeResolver()

        #expect(resolver.project(forDirectory: code + "/pn/packages/ui-kit")?.rootPath == code + "/pn")
        #expect(resolver.project(forDirectory: code + "/rs/crates/parser")?.rootPath == code + "/rs")
        #expect(resolver.project(forDirectory: code + "/gw/svc-a")?.rootPath == code + "/gw", "go.work declares a workspace without a manifest of its own")
        #expect(resolver.project(forDirectory: code + "/gr/app-core")?.rootPath == code + "/gr")
        #expect(resolver.project(forDirectory: code + "/uv/pkgs/etl")?.rootPath == code + "/uv")
        #expect(resolver.project(forDirectory: code + "/mvn/billing")?.rootPath == code + "/mvn")
        let e2e = resolver.project(forDirectory: code + "/tb/apps/storefront/e2e-suite")
        #expect(e2e?.rootPath == code + "/tb", "nested packages reach the outermost workspace")
        #expect(e2e?.subpath == "apps/storefront/e2e-suite")
        #expect(e2e?.name == "tb")
    }

    @Test func composeFileThatBuildsChildrenGroupsThem() {
        let fs = PortResolverTestFS()
        let stack = home + "/Downloads/stack"
        fs.addFile(stack + "/docker-compose.yml", """
            services:
              api:
                build: ./shop-api
              web:
                build:
                  context: shop-web
                volumes:
                  - ./shop-web/src:/app/src
            """)
        fs.addFile(stack + "/shop-api/requirements.txt")
        fs.addFile(stack + "/shop-web/package.json", #"{"name": "shop-web"}"#)
        let other = home + "/Downloads/devtools"
        fs.addFile(other + "/compose.yaml", "services:\n  db:\n    image: postgres:16\n    volumes:\n      - ./pgdata:/var/lib/postgresql/data\n")
        fs.addFile(other + "/alpha/package.json", #"{"name": "alpha-tool"}"#)
        fs.addFile(other + "/beta/package.json", #"{"name": "beta-tool"}"#)
        let resolver = fs.makeResolver()

        #expect(resolver.project(forDirectory: stack + "/shop-api")?.rootPath == stack)
        #expect(resolver.project(forDirectory: stack + "/shop-api")?.subpath == "shop-api")
        #expect(resolver.project(forDirectory: stack + "/shop-web")?.rootPath == stack)
        #expect(resolver.project(forDirectory: other + "/alpha")?.rootPath == other + "/alpha", "a compose file that does not use a folder does not claim it")
        #expect(resolver.project(forDirectory: other + "/beta")?.name == "beta-tool")
    }

    @Test func genericPartDoesNotClimbIntoAContainerFolder() {
        let fs = PortResolverTestFS()
        let projects = home + "/Downloads/projects"
        fs.addFile(projects + "/package.json", #"{"name": "scratch"}"#)
        fs.addFile(projects + "/api/package.json", #"{"name": "api"}"#)
        let info = fs.makeResolver().project(forDirectory: projects + "/api")
        #expect(info?.rootPath == projects + "/api")
        #expect(info?.name == "projects/api")
    }

    @Test func composeReferenceParser() {
        func refs(_ yaml: String, _ folder: String) -> Bool {
            PortProjectResolver.composeFile(Data(yaml.utf8), references: folder)
        }
        #expect(refs("    build: ./api\n", "api"))
        #expect(refs("    build: api\n", "api"))
        #expect(refs("      context: \"./api/\"\n", "api"))
        #expect(refs("      - ./api:/app\n", "api"))
        #expect(refs("      - \"./packages/web/dist:/usr/share/nginx/html\"\n", "packages/web"))
        #expect(refs("    env_file: ./api/.env\n", "api"))
        #expect(!(refs("      - ./api-old:/app\n", "api")))
        #expect(!(refs("    image: api\n", "api")))
        #expect(!(refs("  # build: ./api\n", "api")))
        #expect(!(refs("    build: ./api\n", "")))
    }

    @Test func workspaceManifestParsers() {
        #expect(PortProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"workspaces": ["packages/*"]}"#.utf8)))
        #expect(PortProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"workspaces": {"packages": []}}"#.utf8)))
        #expect(!(PortProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"workspaces": []}"#.utf8))))
        #expect(!(PortProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"name": "x"}"#.utf8))))
        #expect(PortProjectResolver.packageJSONDeclaresWorkspaces(Data(#"{"name": "x", "workspaces": ["a"#.utf8)), "truncated JSON falls back to a textual check")

        #expect(PortProjectResolver.packageJSONDescribesProject(Data(#"{"name": "x"}"#.utf8)))
        #expect(PortProjectResolver.packageJSONDescribesProject(Data(#"{"scripts": {"dev": "vite"}}"#.utf8)))
        #expect(!(PortProjectResolver.packageJSONDescribesProject(Data(#"{"dependencies": {"a": "1"}}"#.utf8))))
        #expect(PortProjectResolver.packageJSONDescribesProject(Data("{ broken".utf8)))

        let cargo = { (text: String) in PortProjectResolver.tomlDeclaresTable(Data(text.utf8), named: "workspace") }
        #expect(cargo("[workspace]\nmembers = []\n"))
        #expect(cargo("[package]\nname = \"a\"\n\n[workspace.dependencies]\nserde = \"1\"\n"))
        #expect(!(cargo("[package]\nname = \"a\"\n[[bin]]\nname = \"workspace\"\n")))
        #expect(!(cargo("[workspaces]\n")))

        #expect(PortProjectResolver.gradleSettingsIncludeProjects("rootProject.name = 'x'\ninclude 'app', 'lib'\n"))
        #expect(!(PortProjectResolver.gradleSettingsIncludeProjects("rootProject.name = 'x'\n")))
    }
}

/// GUI apps the user builds belong to their project; installed apps never do.
@Suite struct PortProjectResolverAppTests {
    private let home = PortResolverTestFS.home

    private func app(_ executable: String, cwd: String = "/") -> PortProcessDetails {
        PortResolverTestProcess.details(executable: executable, arguments: [executable], cwd: cwd)
    }

    private func derivedDataPlist(workspace: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>LastAccessedDate</key><date>2026-10-09T10:28:32Z</date>
        <key>WorkspacePath</key><string>\(workspace)</string>
        </dict></plist>
        """
    }

    @Test func appBuiltInsideAProjectBelongsToIt() {
        let fs = PortResolverTestFS()
        let tool = home + "/Downloads/odds-and-ends/MyMacTool"
        fs.addDirectory(tool + "/.git")
        fs.addFile(tool + "/Package.swift")
        let executable = tool + "/build/Debug/MyMacTool.app/Contents/MacOS/MyMacTool"
        fs.addFile(executable)
        let electron = home + "/code/desk"
        fs.addFile(electron + "/package.json", #"{"name": "desk"}"#)
        let helper = electron + "/dist/mac-arm64/Desk.app/Contents/Frameworks/Desk Helper.app/Contents/MacOS/Desk Helper"
        let resolver = fs.makeResolver()

        let details = app(executable, cwd: tool)
        let info = resolver.resolve(details: details)
        #expect(info?.rootPath == tool)
        #expect(info?.name == "MyMacTool")
        let basic = PortProcessBasic(pid: 100, ppid: 1, pgid: 100, uid: 501, comm: "MyMacTool", startTime: 1)
        #expect(PortClassifier.category(basic: basic, details: details, project: info, manager: .none,
                                           currentUID: 501) == .project)
        #expect(resolver.resolve(details: app(helper))?.rootPath == electron, "helpers of a packaged build resolve through the outermost bundle")
    }

    @Test func xcodeBuildProductsResolveThroughDerivedData() {
        let fs = PortResolverTestFS()
        let derived = home + "/Library/Developer/Xcode/DerivedData"
        let myApp = home + "/code/MyApp"
        fs.addDirectory(myApp + "/.git")
        fs.addFile(derived + "/MyApp-abc/info.plist", derivedDataPlist(workspace: myApp + "/MyApp.xcodeproj"))
        let package = home + "/Downloads/swift sketches/MenuTimer"
        fs.addFile(package + "/Package.swift")
        fs.addFile(derived + "/MenuTimer-def/info.plist", derivedDataPlist(workspace: package))
        let bare = home + "/Downloads/Field Notes/Field Notes"
        fs.addDirectory(bare + "/Field Notes.xcodeproj")
        fs.addFile(derived + "/Field_Notes-ghi/info.plist",
                   derivedDataPlist(workspace: bare + "/Field Notes.xcodeproj/project.xcworkspace"))
        let custom = "/private/tmp/dd"
        let tmpProject = "/private/tmp/work/Tool"
        fs.addDirectory(tmpProject + "/.git")
        fs.addFile(custom + "/info.plist", derivedDataPlist(workspace: tmpProject + "/Tool.xcodeproj"))
        let resolver = fs.makeResolver()

        let product = derived + "/MyApp-abc/Build/Products/Debug/MyApp.app/Contents/MacOS/MyApp"
        #expect(resolver.resolve(details: app(product))?.rootPath == myApp)
        #expect(resolver.resolve(details: app(product))?.name == "MyApp")

        let packageProduct = derived + "/MenuTimer-def/Build/Products/Release/MenuTimer.app/Contents/MacOS/MenuTimer"
        #expect(resolver.resolve(details: app(packageProduct))?.rootPath == package)

        let bareInfo = resolver.resolve(details: app(
            derived + "/Field_Notes-ghi/Build/Products/Debug/Field Notes.app/Contents/MacOS/Field Notes"))
        #expect(bareInfo?.rootPath == bare)
        #expect(bareInfo?.markers == ["Field Notes.xcodeproj"], "the Xcode project is the marker")

        #expect(resolver.resolve(details: app(custom + "/Build/Products/Debug/Tool.app/Contents/MacOS/Tool"))?
                        .rootPath == tmpProject, "custom -derivedDataPath folders work too")

        #expect(resolver.resolve(details: app(derived + "/Gone-xyz/Build/Products/Debug/Gone.app/Contents/MacOS/Gone")) == nil, "without info.plist the build product stays an app")
    }

    @Test func xcodeCommandLineServerResolvesThroughDerivedData() {
        let fs = PortResolverTestFS()
        let derived = home + "/Library/Developer/Xcode/DerivedData/vapor-api-abc"
        let package = home + "/Downloads/vapor-api"
        fs.addFile(package + "/Package.swift")
        fs.addFile(derived + "/info.plist", derivedDataPlist(workspace: package))
        let server = PortResolverTestProcess.details(executable: derived + "/Build/Products/Debug/App",
                                                 arguments: [derived + "/Build/Products/Debug/App", "serve"], cwd: "/")
        let info = fs.makeResolver().resolve(details: server)
        #expect(info?.rootPath == package)
        #expect(info?.markers == ["Package.swift"])
    }

    @Test func installedAppsNeverGetAProject() {
        let fs = PortResolverTestFS()
        let project = home + "/code/site"
        fs.addDirectory(project + "/.git")
        fs.addFile(project + "/package.json", #"{"name": "site"}"#)
        fs.addFile(home + "/Downloads/Tool-1.2/README.txt")
        let resolver = fs.makeResolver()

        let installed = [
            "/Applications/Tool.app/Contents/MacOS/Tool",
            home + "/Applications/Tool.app/Contents/MacOS/Tool",
            home + "/Downloads/Tool.app/Contents/MacOS/Tool",
            home + "/Downloads/Tool-1.2/Tool.app/Contents/MacOS/Tool",
            home + "/Library/Application Support/Vendor/Agent.app/Contents/MacOS/Agent",
            "/opt/homebrew/Caskroom/tool/1.0/Tool.app/Contents/MacOS/Tool",
        ]
        for executable in installed {
            #expect(resolver.resolve(details: app(executable, cwd: project)) == nil, "\(executable)")
        }
    }

    @Test func workspaceLocation() {
        #expect(PortProjectResolver.workspaceLocation(forWorkspacePath: "/u/a/App.xcodeproj")?.directory == "/u/a")
        #expect(PortProjectResolver.workspaceLocation(forWorkspacePath: "/u/a/App.xcodeproj")?.fileName == "App.xcodeproj")
        #expect(PortProjectResolver.workspaceLocation(forWorkspacePath: "/u/a/App.xcworkspace")?.directory == "/u/a")
        #expect(PortProjectResolver.workspaceLocation(
            forWorkspacePath: "/u/a/App.xcodeproj/project.xcworkspace")?.directory == "/u/a")
        #expect(PortProjectResolver.workspaceLocation(
            forWorkspacePath: "/u/pkg/.swiftpm/xcode/package.xcworkspace")?.directory == "/u/pkg")
        #expect(PortProjectResolver.workspaceLocation(forWorkspacePath: "/u/pkg")?.directory == "/u/pkg")
        #expect(PortProjectResolver.workspaceLocation(forWorkspacePath: "/") == nil)
    }
}

/// `resolve(details:)` must not stall the scan while macOS shows a folder-access prompt.
@Suite struct PortProjectResolverDeadlineTests {
    private let home = PortResolverTestFS.home

    private func node(cwd: String, script: String = "server.js") -> PortProcessDetails {
        PortResolverTestProcess.details(executable: "/opt/homebrew/bin/node", arguments: ["node", script], cwd: cwd)
    }

    @Test func blockedProbeAnswersProvisionallyThenCachesTheRealAnswer() {
        let fs = PortResolverTestFS()
        let project = home + "/Downloads/slowproj"
        fs.addDirectory(project + "/.git")
        fs.addFile(project + "/web/package.json", #"{"name": "slow-web"}"#)
        fs.blockProbes(under: project)
        defer { fs.releaseBlockedProbes() }
        let resolver = fs.makeResolver(probeDeadline: 0.5)
        let server = node(cwd: project + "/web")

        var started = Date()
        let provisional = resolver.resolve(details: server)
        #expect(Date().timeIntervalSince(started) < 2, "the caller waits about one deadline, not the prompt")
        #expect(provisional?.rootPath == project + "/web")
        #expect(provisional?.name == "slowproj/web")
        #expect(provisional?.markers == [])
        #expect(resolver.foldersAwaitingAccess() == [home + "/Downloads"])

        started = Date()
        #expect(resolver.resolve(details: server)?.rootPath == project + "/web")
        #expect(Date().timeIntervalSince(started) < 0.25, "a stalled folder answers at once")
        #expect(resolver.pendingProbeCount == 1, "repeated scans share the blocked probe")

        fs.releaseBlockedProbes()
        #expect(resolver.waitForPendingProbes(timeout: 5))
        #expect(resolver.foldersAwaitingAccess() == [])
        #expect(resolver.pendingProbeCount == 0)

        let real = resolver.resolve(details: server)
        #expect(real?.rootPath == project)
        #expect(real?.name == "slowproj")
        #expect(real?.subpath == "web")
    }

    @Test func stalledFolderDoesNotDelayOtherFolders() {
        let fs = PortResolverTestFS()
        let slow = home + "/Downloads/slowproj"
        fs.addFile(slow + "/package.json", #"{"name": "slow"}"#)
        let fast = home + "/code/fast"
        fs.addFile(fast + "/package.json", #"{"name": "fast"}"#)
        let documents = home + "/Documents/notes"
        fs.addFile(documents + "/requirements.txt")
        fs.blockProbes(under: slow)
        defer { fs.releaseBlockedProbes() }
        let resolver = fs.makeResolver(probeDeadline: 0.5)

        #expect(resolver.resolve(details: node(cwd: slow))?.markers == [], "provisional")

        var started = Date()
        #expect(resolver.resolve(details: node(cwd: fast))?.name == "fast")
        #expect(resolver.resolve(details: node(cwd: documents))?.markers == ["requirements.txt"])
        #expect(Date().timeIntervalSince(started) < 0.25, "other folders keep their own probe queues")

        started = Date()
        let tool = PortResolverTestProcess.details(executable: home + "/.local/bin/indexer", arguments: ["indexer"],
                                               cwd: slow + "/sub")
        #expect(resolver.resolve(details: tool) == nil, "no provisional project for a tool that inherited the cwd")
        #expect(Date().timeIntervalSince(started) < 0.25)

        fs.releaseBlockedProbes()
        #expect(resolver.waitForPendingProbes(timeout: 5))
        #expect(resolver.resolve(details: node(cwd: slow))?.markers == ["package.json"])
        #expect(resolver.resolve(details: tool)?.rootPath == slow, "the real answer: its cwd lies inside a project with markers")
    }

    @Test func buildProductsAreProbedInTheirWorkspaceFolder() {
        let fs = PortResolverTestFS()
        let derived = home + "/Library/Developer/Xcode/DerivedData/Sunbeam-abc"
        let project = home + "/Downloads/Pixelpost/Sunbeam"
        fs.addDirectory(project + "/.git")
        fs.addFile(derived + "/info.plist", """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>WorkspacePath</key>\
            <string>\(project)/Sunbeam.xcodeproj</string></dict></plist>
            """)
        fs.blockProbes(under: project)
        defer { fs.releaseBlockedProbes() }
        let resolver = fs.makeResolver(probeDeadline: 0.3)
        let app = PortResolverTestProcess.details(
            executable: derived + "/Build/Products/Debug/Sunbeam.app/Contents/MacOS/Sunbeam",
            arguments: ["Sunbeam"], cwd: "/")

        #expect(resolver.resolve(details: app) == nil, "apps get no provisional project")
        #expect(resolver.foldersAwaitingAccess() == [home + "/Downloads"], "the probe waits in the workspace's folder, not in the shared queue")
        fs.releaseBlockedProbes()
        #expect(resolver.waitForPendingProbes(timeout: 5))
        #expect(resolver.resolve(details: app)?.rootPath == project)
    }

    @Test func fastProbesAnswerDirectly() {
        let fs = PortResolverTestFS()
        fs.addFile(home + "/Downloads/quick/package.json", #"{"name": "quick"}"#)
        let resolver = fs.makeResolver(probeDeadline: PortProjectResolver.defaultProbeDeadline)
        #expect(resolver.resolve(details: node(cwd: home + "/Downloads/quick"))?.markers == ["package.json"])
        #expect(resolver.pendingProbeCount == 0)
        #expect(resolver.foldersAwaitingAccess() == [])
    }

    @Test func provisionalProjectRules() {
        let resolver = PortProjectResolver(homeDirectory: home, fileExists: { _ in
            Issue.record("provisional answers must not touch the disk")
            return false
        }, readFile: { _ in nil })

        let runtime = resolver.provisionalProject(for: node(cwd: home + "/Downloads/a/b"))
        #expect(runtime?.rootPath == home + "/Downloads/a/b")
        #expect(runtime?.name == "b")
        #expect(resolver.provisionalProject(for: node(cwd: "/", script: home + "/Sites/demo/server.js"))?
                        .rootPath == home + "/Sites/demo")
        #expect(resolver.provisionalProject(for: node(cwd: home + "/code/app/node_modules/.bin"))?.rootPath == home + "/code/app")
        #expect(resolver.provisionalProject(for: PortResolverTestProcess.details(
            executable: home + "/code/svc/server", arguments: ["./server"], cwd: home + "/code/svc"))?.rootPath == home + "/code/svc", "a binary that lives in its working folder")

        #expect(resolver.provisionalProject(for: PortResolverTestProcess.details(
            executable: home + "/code/svc/bin/tool", arguments: ["tool"], cwd: home + "/code/svc")) == nil)
        #expect(resolver.provisionalProject(for: PortResolverTestProcess.details(
            executable: home + "/.local/bin/tool", arguments: ["tool"], cwd: home + "/Downloads/x")) == nil)
        #expect(resolver.provisionalProject(for: PortResolverTestProcess.details(
            executable: home + "/Downloads/x/build/X.app/Contents/MacOS/X", arguments: ["X"], cwd: home + "/Downloads/x")) == nil)
        #expect(resolver.provisionalProject(for: node(cwd: home + "/Library/Application Support/x")) == nil)
        #expect(resolver.provisionalProject(for: node(cwd: "/opt/app")) == nil, "outside $HOME only with markers")
        #expect(resolver.provisionalProject(for: node(cwd: home + "/Downloads")) == nil)
    }

    @Test func protectedFolders() {
        let resolver = PortResolverTestFS().makeResolver()
        #expect(resolver.protectedFolder(containing: home + "/Downloads/a/b") == home + "/Downloads")
        #expect(resolver.protectedFolder(containing: home + "/Documents/x") == home + "/Documents")
        #expect(resolver.protectedFolder(containing: home + "/Desktop/x") == home + "/Desktop")
        #expect(resolver.protectedFolder(containing: home + "/Library/Mobile Documents/com~apple~CloudDocs/x") == home + "/Library/Mobile Documents")
        #expect(resolver.protectedFolder(containing: home + "/Library/CloudStorage/Dropbox/x") == home + "/Library/CloudStorage/Dropbox")
        #expect(resolver.protectedFolder(containing: "/Volumes/SSD/code/x") == "/Volumes/SSD")
        #expect(resolver.protectedFolder(containing: home + "/code/x") == nil)
        #expect(resolver.protectedFolder(containing: home + "/Library/Developer/Xcode/DerivedData/x") == nil)
        #expect(resolver.protectedFolder(containing: "/opt/homebrew/bin/node") == nil)
    }
}
