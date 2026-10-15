import AppKit
import Foundation

/// Script interpreters that a launchd job can start with code instead of a program.
enum LaunchdInterpreterKind: String, Sendable, Hashable, CaseIterable {
    case shell, python, perl, ruby, node, osascript, php, tcl, powershell, deno, bun

    var title: String {
        switch self {
        case .shell: return "shell"
        case .python: return "Python"
        case .perl: return "Perl"
        case .ruby: return "Ruby"
        case .node: return "Node.js"
        case .osascript: return "AppleScript"
        case .php: return "PHP"
        case .tcl: return "Tcl"
        case .powershell: return "PowerShell"
        case .deno: return "Deno"
        case .bun: return "Bun"
        }
    }

    /// Recognizes an interpreter from an executable name such as `python3.12` or `/bin/zsh`.
    static func from(executableName rawName: String) -> LaunchdInterpreterKind? {
        let name = (rawName as NSString).lastPathComponent.lowercased()
        // Strip version suffixes: python3.12 → python, perl5.30 → perl, tclsh8.6 → tclsh.
        let base = String(name.prefix { $0.isLetter || $0 == "_" })
        switch base {
        case "sh", "bash", "zsh", "dash", "ksh", "mksh", "csh", "tcsh", "fish": return .shell
        case "python", "pythonw", "pypy": return .python
        case "perl": return .perl
        case "ruby": return .ruby
        case "node", "nodejs": return .node
        case "osascript": return .osascript
        case "php": return .php
        case "tclsh", "wish", "expect": return .tcl
        case "pwsh", "powershell": return .powershell
        case "deno": return .deno
        case "bun": return .bun
        default: return nil
        }
    }
}

/// What a launchd job effectively runs, resolved from its property list.
struct LaunchdProgramAnalysis: Sendable, Hashable {
    enum TargetKind: String, Sendable, Hashable {
        case program, application, script, inlineCode, url, unknown
    }

    /// Absolute path of the executable launchd starts (`argv[0]`), when it could be resolved.
    var executable: String?
    var executableExists = false
    /// Set when the executable is a script interpreter.
    var interpreter: LaunchdInterpreterKind?
    var interpreterName: String?
    /// Code passed on the command line (`sh -c`, `python -c`, `osascript -e`...).
    var inlineCode: String?
    /// Script file passed to an interpreter.
    var scriptPath: String?
    /// `python -m module`.
    var moduleName: String?
    /// The job runs `/usr/bin/open` to open an app, file or URL.
    var isOpenCommand = false
    var openTarget: String?
    /// The item that matters for review: the opened app, the script, or the program itself.
    var targetPath: String?
    var targetKind: TargetKind = .unknown
    var targetExists = false
    /// Outermost `.app` bundle containing the target, if any.
    var enclosingAppPath: String?
    var arguments: [String] = []

    /// The argument vector as one display line, with arguments that contain spaces quoted.
    var commandLine: String {
        arguments.map { argument in
            argument.contains(where: { $0 == " " || $0 == "\t" }) || argument.isEmpty
                ? "\"" + argument.replacingOccurrences(of: "\"", with: "\\\"") + "\""
                : argument
        }.joined(separator: " ")
    }

    /// `true` when the job points at something that no longer exists.
    var isBroken: Bool {
        if executable != nil && !executableExists { return true }
        switch targetKind {
        case .application: return !targetExists
        case .program, .script: return targetPath != nil && !targetExists
        case .inlineCode, .url, .unknown: return false
        }
    }

    /// Short description of the target for lists ("Opens Spotify", "Runs a Python script").
    var targetDescription: String {
        switch targetKind {
        case .application:
            if let targetPath { return "Opens " + ((targetPath as NSString).lastPathComponent as NSString).deletingPathExtension }
            return "Opens " + (openTarget ?? "an app")
        case .script:
            return "Runs a \(interpreter?.title ?? "script") script"
        case .inlineCode:
            return "Runs inline \(interpreter?.title ?? "script") code"
        case .url:
            return "Opens a web address"
        case .program:
            if let moduleName { return "Runs the \(interpreter?.title ?? "") module \(moduleName)" }
            return "Runs " + ((targetPath ?? executable ?? "a program") as NSString).lastPathComponent
        case .unknown:
            return executable.map { "Runs " + ($0 as NSString).lastPathComponent } ?? "No program"
        }
    }
}

/// Resolves what a launchd job runs: bundle-relative programs, interpreters with
/// scripts or inline code, `/usr/bin/env` wrappers and `/usr/bin/open` commands.
enum LaunchdProgramAnalyzer {
    /// File-system lookups, injectable so tests don't depend on this Mac.
    struct Environment: Sendable {
        var fileExists: @Sendable (String) -> Bool
        var appPathForBundleIdentifier: @Sendable (String) -> String?
        var home: String

        /// Paths that can't be checked (no permission) count as existing, so they're never called broken.
        static let live = Environment(
            fileExists: { LaunchdPathProbe.mightExist($0) },
            appPathForBundleIdentifier: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path },
            home: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    /// Folders searched for executables named without a path (launchd's default `PATH` plus package managers).
    static let searchPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]

    static func analyze(
        _ job: LaunchdJobDefinition,
        plistPath: String? = nil,
        bundlePath explicitBundlePath: String? = nil,
        environment: Environment = .live
    ) -> LaunchdProgramAnalysis {
        let bundlePath = explicitBundlePath ?? plistPath.flatMap(outermostAppBundle(in:))
        var analysis = LaunchdProgramAnalysis()
        var argv = job.argumentVector

        // Resolve argv[0] / Program to an absolute executable.
        var executable: String?
        if let program = job.program, !program.isEmpty {
            executable = resolve(program, bundlePath: bundlePath, environment: environment)
        } else if let bundleProgram = job.bundleProgram, !bundleProgram.isEmpty, let bundlePath {
            executable = PathUtilities.join(bundlePath, bundleProgram)
        } else if let first = argv.first {
            executable = resolve(first, bundlePath: bundlePath, environment: environment)
        }
        if argv.isEmpty, let executable { argv = [executable] }
        analysis.arguments = argv

        guard var current = executable else { return analysis }
        var rest = Array(argv.dropFirst())

        // `/usr/bin/env [options] [NAME=value...] utility args...`
        if (current as NSString).lastPathComponent == "env" {
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                if argument == "-u" || argument == "-P" { index += 2; continue }
                if argument.hasPrefix("-") || argument.contains("=") { index += 1; continue }
                break
            }
            if index < rest.count {
                analysis.executable = current
                analysis.executableExists = environment.fileExists(current)
                current = resolve(rest[index], bundlePath: bundlePath, environment: environment)
                rest = Array(rest.dropFirst(index + 1))
            }
        }

        analysis.executable = current
        analysis.executableExists = environment.fileExists(current)

        if current == "/usr/bin/open" {
            analysis.isOpenCommand = true
            analyzeOpen(arguments: rest, into: &analysis, environment: environment)
        } else if let kind = LaunchdInterpreterKind.from(executableName: current) {
            analysis.interpreter = kind
            analysis.interpreterName = (current as NSString).lastPathComponent
            let parsed = interpreterArguments(rest, kind: kind)
            analysis.inlineCode = parsed.inline
            analysis.moduleName = parsed.module
            if let script = parsed.script, script != "-" {
                analysis.scriptPath = absoluteScriptPath(script, workingDirectory: job.workingDirectory)
            }
            if analysis.inlineCode != nil {
                analysis.targetKind = .inlineCode
                analysis.targetPath = current
                analysis.targetExists = analysis.executableExists
            } else if let script = analysis.scriptPath {
                analysis.targetKind = .script
                analysis.targetPath = script
                analysis.targetExists = environment.fileExists(script)
            } else if parsed.script != nil && parsed.script != "-" {
                // A relative script without a working directory can't be located; judge by the interpreter only.
                analysis.targetKind = .script
                analysis.targetExists = analysis.executableExists
            } else {
                analysis.targetKind = .program
                analysis.targetPath = current
                analysis.targetExists = analysis.executableExists
            }
        } else {
            analysis.targetKind = current.hasSuffix(".app") ? .application : .program
            analysis.targetPath = current
            analysis.targetExists = analysis.executableExists
        }

        if let target = analysis.targetPath {
            analysis.enclosingAppPath = outermostAppBundle(in: target)
        }
        return analysis
    }

    // MARK: - /usr/bin/open

    private static func analyzeOpen(arguments: [String], into analysis: inout LaunchdProgramAnalysis, environment: Environment) {
        var appArgument: String?
        var bundleIdentifier: String?
        var positional: String?
        let optionsWithValue: Set<String> = ["-a", "-b", "-u", "-s", "-i", "-o", "--env", "--stdin", "--stdout", "--stderr", "--arch"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--args" { break }
            if argument == "-a", index + 1 < arguments.count { appArgument = arguments[index + 1]; index += 2; continue }
            if argument == "-b", index + 1 < arguments.count { bundleIdentifier = arguments[index + 1]; index += 2; continue }
            if optionsWithValue.contains(argument) { index += 2; continue }
            if argument.hasPrefix("-") { index += 1; continue }
            if positional == nil { positional = argument }
            index += 1
        }

        if let appArgument {
            analysis.openTarget = appArgument
            let path = resolveApplication(appArgument, environment: environment)
            analysis.targetKind = .application
            analysis.targetPath = path ?? (appArgument.hasPrefix("/") ? appArgument : nil)
            analysis.targetExists = path.map(environment.fileExists) ?? false
        } else if let bundleIdentifier {
            analysis.openTarget = bundleIdentifier
            let path = environment.appPathForBundleIdentifier(bundleIdentifier)
            analysis.targetKind = .application
            analysis.targetPath = path
            analysis.targetExists = path != nil
        } else if let positional {
            analysis.openTarget = positional
            if positional.contains("://") && !positional.hasPrefix("file://") {
                analysis.targetKind = .url
                analysis.targetPath = nil
                analysis.targetExists = true
            } else {
                let path = positional.hasPrefix("file://") ? (URL(string: positional)?.path ?? positional) : positional
                analysis.targetKind = path.hasSuffix(".app") ? .application : .program
                analysis.targetPath = path
                analysis.targetExists = environment.fileExists(path)
            }
        } else {
            analysis.targetKind = .unknown
        }
    }

    /// Resolves `open -a` arguments, which may be a path or just an application name.
    static func resolveApplication(_ argument: String, environment: Environment) -> String? {
        if argument.hasPrefix("/") { return argument.hasSuffix("/") ? String(argument.dropLast()) : argument }
        let name = argument.hasSuffix(".app") ? argument : argument + ".app"
        let folders = ["/Applications", environment.home + "/Applications", "/System/Applications",
                       "/System/Applications/Utilities", "/Applications/Utilities", "/System/Library/CoreServices"]
        for folder in folders {
            let candidate = folder + "/" + name
            if environment.fileExists(candidate) { return candidate }
        }
        return nil
    }

    // MARK: - Interpreters

    private static func interpreterArguments(_ arguments: [String], kind: LaunchdInterpreterKind) -> (inline: String?, script: String?, module: String?) {
        func value(after index: Int) -> String? { index + 1 < arguments.count ? arguments[index + 1] : nil }
        var index = 0
        switch kind {
        case .shell:
            var wantsInline = false
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" { index += 1; break }
                if ["-o", "+o", "-O", "+O"].contains(argument) { index += 2; continue }
                if argument.hasPrefix("--") { index += 1; continue }
                if (argument.hasPrefix("-") || argument.hasPrefix("+")), argument.count > 1 {
                    if argument.dropFirst().contains("c") { wantsInline = true }
                    index += 1
                    continue
                }
                break
            }
            guard index < arguments.count else { return (nil, nil, nil) }
            return wantsInline ? (arguments[index], nil, nil) : (nil, arguments[index], nil)

        case .python:
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "-c" { return (value(after: index), nil, nil) }
                if argument.hasPrefix("-c"), argument.count > 2, !argument.hasPrefix("--") { return (String(argument.dropFirst(2)), nil, nil) }
                if argument == "-m" { return (nil, nil, value(after: index)) }
                if argument.hasPrefix("-m"), argument.count > 2, !argument.hasPrefix("--") { return (nil, nil, String(argument.dropFirst(2))) }
                if ["-W", "-X", "-Q"].contains(argument) { index += 2; continue }
                if argument == "-" { return (nil, nil, nil) }
                if argument.hasPrefix("-") { index += 1; continue }
                return (nil, argument, nil)
            }

        case .perl:
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "--" { index += 1; break }
                if argument.hasPrefix("-"), argument.count > 1 {
                    let flags = argument.dropFirst()
                    if flags.allSatisfy(\.isLetter), let last = flags.last, last == "e" || last == "E" {
                        return (value(after: index), nil, nil)
                    }
                    if ["-I", "-M", "-m", "-x"].contains(argument) { index += 2; continue }
                    index += 1
                    continue
                }
                return (nil, argument, nil)
            }
            return index < arguments.count ? (nil, arguments[index], nil) : (nil, nil, nil)

        case .ruby:
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "-e" { return (value(after: index), nil, nil) }
                if ["-r", "-I", "-C", "-E"].contains(argument) { index += 2; continue }
                if argument.hasPrefix("-") { index += 1; continue }
                return (nil, argument, nil)
            }

        case .node, .bun:
            if kind == .bun, arguments.first == "run" { index = 1 }
            while index < arguments.count {
                let argument = arguments[index]
                if ["-e", "--eval", "-p", "--print"].contains(argument) { return (value(after: index), nil, nil) }
                if argument.hasPrefix("--eval=") { return (String(argument.dropFirst("--eval=".count)), nil, nil) }
                if ["-r", "--require", "--import", "--loader", "--env-file", "--cwd"].contains(argument) { index += 2; continue }
                if argument.hasPrefix("-") { index += 1; continue }
                return (nil, argument, nil)
            }

        case .deno:
            guard let subcommand = arguments.first else { return (nil, nil, nil) }
            let remainder = Array(arguments.dropFirst())
            let positional = remainder.first { !$0.hasPrefix("-") }
            if subcommand == "eval" { return (positional, nil, nil) }
            if subcommand == "run" { return (nil, positional, nil) }
            return (nil, subcommand.hasPrefix("-") ? nil : subcommand, nil)

        case .osascript:
            var statements: [String] = []
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "-e", let statement = value(after: index) { statements.append(statement); index += 2; continue }
                if ["-l", "-s"].contains(argument) { index += 2; continue }
                if argument.hasPrefix("-") { index += 1; continue }
                break
            }
            if !statements.isEmpty { return (statements.joined(separator: "\n"), nil, nil) }
            return index < arguments.count ? (nil, arguments[index], nil) : (nil, nil, nil)

        case .php:
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "-r" { return (value(after: index), nil, nil) }
                if argument == "-f" { return (nil, value(after: index), nil) }
                if ["-c", "-d", "-z"].contains(argument) { index += 2; continue }
                if argument.hasPrefix("-") { index += 1; continue }
                return (nil, argument, nil)
            }

        case .tcl:
            while index < arguments.count {
                let argument = arguments[index]
                if argument == "-c" { return (value(after: index), nil, nil) }
                if argument == "-f" { return (nil, value(after: index), nil) }
                if argument.hasPrefix("-") { index += 1; continue }
                return (nil, argument, nil)
            }

        case .powershell:
            while index < arguments.count {
                let argument = arguments[index]
                let lowered = argument.lowercased()
                if ["-command", "-c", "-encodedcommand", "-e", "-ec", "-enc"].contains(lowered) { return (value(after: index), nil, nil) }
                if ["-file", "-f"].contains(lowered) { return (nil, value(after: index), nil) }
                if ["-executionpolicy", "-ex", "-workingdirectory", "-wd", "-configurationname", "-settingsfile"].contains(lowered) { index += 2; continue }
                if argument.hasPrefix("-") { index += 1; continue }
                return (nil, argument, nil)
            }
        }
        return (nil, nil, nil)
    }

    // MARK: - Paths

    private static func resolve(_ raw: String, bundlePath: String?, environment: Environment) -> String {
        if raw.hasPrefix("/") { return raw }
        if let bundlePath, raw.contains("/") { return PathUtilities.join(bundlePath, raw) }
        if !raw.contains("/") {
            for folder in searchPath where environment.fileExists(folder + "/" + raw) {
                return folder + "/" + raw
            }
        }
        if let bundlePath { return PathUtilities.join(bundlePath, raw) }
        return raw
    }

    private static func absoluteScriptPath(_ script: String, workingDirectory: String?) -> String? {
        if script.hasPrefix("/") { return script }
        if let workingDirectory, workingDirectory.hasPrefix("/") {
            return PathUtilities.normalize(PathUtilities.join(workingDirectory, script))
        }
        return nil
    }

    /// `/Applications/Foo.app/Contents/Library/LoginItems/Helper.app/...` → `/Applications/Foo.app`.
    static func outermostAppBundle(in path: String) -> String? {
        var current = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            if component.lowercased().hasSuffix(".app") { return current }
        }
        return nil
    }

    /// Innermost `.app` bundle containing `path` (or `path` itself when it is an app).
    static func innermostAppBundle(in path: String) -> String? {
        var current = ""
        var found: String?
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            if component.lowercased().hasSuffix(".app") { found = current }
        }
        return found
    }
}
