import SwiftUI

/// Release notes turned into readable blocks: headings, paragraphs, list items and code.
///
/// Developers publish notes as Markdown (GitHub releases), HTML (Sparkle feeds and
/// release-notes pages) or plain text (the App Store). Everything is reduced to text;
/// remote images and scripts are never loaded, and only web links stay clickable.
struct ReleaseNotesDocument: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case heading(String, level: Int)
        /// Inline Markdown (bold, italic, code and links).
        case paragraph(String)
        case bullet(String, depth: Int)
        case numbered(String, number: String)
        case code(String)
        case rule
    }

    var blocks: [Block]

    /// Long notes are cut here, so rendering stays fast.
    static let maximumCharacters = 20_000

    var isEmpty: Bool { blocks.isEmpty }

    /// HTML when the text contains tags, Markdown otherwise.
    static func detect(_ text: String) -> ReleaseNotesDocument {
        looksLikeHTML(text) ? html(text) : markdown(text)
    }

    static func looksLikeHTML(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["<p", "<li", "<br", "<h1", "<h2", "<h3", "<ul", "<div", "<body", "<html"].contains { lowered.contains($0) }
    }

    // MARK: Markdown

    static func markdown(_ source: String) -> ReleaseNotesDocument {
        let text = String(source.prefix(maximumCharacters)).replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String]?

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if let lines = codeLines {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            if let item = bulletItem(trimmed) {
                flushParagraph()
                let cleaned = inline(item)
                if !cleaned.isEmpty { blocks.append(.bullet(cleaned, depth: min(3, indent / 2))) }
                continue
            }
            if let (number, item) = numberedItem(trimmed) {
                flushParagraph()
                let cleaned = inline(item)
                if !cleaned.isEmpty { blocks.append(.numbered(cleaned, number: number)) }
                continue
            }
            var content = trimmed
            while content.hasPrefix(">") { content = String(content.dropFirst()).trimmingCharacters(in: .whitespaces) }
            let cleaned = inline(content)
            if !cleaned.isEmpty { paragraph.append(cleaned) }
        }
        if let lines = codeLines, !lines.isEmpty { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        return ReleaseNotesDocument(blocks: blocks)
    }

    /// Plain text (App Store notes): every line is kept; "•", "-" and "*" start list items.
    static func plainText(_ source: String) -> ReleaseNotesDocument {
        var blocks: [Block] = []
        for line in String(source.prefix(maximumCharacters)).components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let first = trimmed.first, ["•", "-", "*", "–", "·"].contains(first), trimmed.count > 1 {
                let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { blocks.append(.bullet(escaped(item), depth: 0)) }
            } else {
                blocks.append(.paragraph(escaped(trimmed)))
            }
        }
        return ReleaseNotesDocument(blocks: blocks)
    }

    private static func heading(_ line: String) -> Block? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        let title = inline(rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces))
        return title.isEmpty ? nil : .heading(title, level: hashes)
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            var item = String(line.dropFirst(marker.count))
            // Task lists: "- [x] Done".
            for box in ["[ ] ", "[x] ", "[X] "] where item.hasPrefix(box) { item = String(item.dropFirst(box.count)) }
            return item
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")", rest.dropFirst().first == " " else { return nil }
        return (String(digits), String(rest.dropFirst(2)))
    }

    /// Removes images and raw HTML tags from a line of inline Markdown.
    static func inline(_ text: String) -> String {
        var result = text
        // ![alt](url): images are never loaded.
        while let start = result.range(of: "!["),
              let close = result.range(of: "](", range: start.upperBound..<result.endIndex),
              let end = result.range(of: ")", range: close.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        result = stripTags(result)
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Escapes Markdown punctuation in plain text, so it's shown as written.
    private static func escaped(_ text: String) -> String {
        var output = ""
        for character in text {
            if "\\`*_[]#".contains(character) { output.append("\\") }
            output.append(character)
        }
        return output
    }

    // MARK: HTML

    static func html(_ source: String) -> ReleaseNotesDocument {
        var text = String(source.prefix(maximumCharacters * 2))
        // Only the body of a full page, without scripts, styles and comments.
        if let body = text.range(of: "<body", options: .caseInsensitive),
           let bodyStart = text.range(of: ">", range: body.upperBound..<text.endIndex) {
            text = String(text[bodyStart.upperBound...])
            if let end = text.range(of: "</body", options: .caseInsensitive) { text = String(text[..<end.lowerBound]) }
        }
        for element in ["script", "style", "head", "nav", "footer"] {
            text = removingElements(element, from: text)
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)

        // Preformatted text keeps its line breaks; everywhere else whitespace collapses.
        var pieces: [String] = []
        var remaining = Substring(text)
        while let open = remaining.range(of: "<pre", options: .caseInsensitive) {
            pieces.append(collapsed(String(remaining[..<open.lowerBound])))
            guard let openEnd = remaining.range(of: ">", range: open.upperBound..<remaining.endIndex),
                  let close = remaining.range(of: "</pre>", options: .caseInsensitive, range: openEnd.upperBound..<remaining.endIndex) else {
                remaining = remaining[open.upperBound...]
                continue
            }
            let code = decodeEntities(stripTags(String(remaining[openEnd.upperBound..<close.lowerBound])))
            pieces.append("\n```\n" + code.trimmingCharacters(in: .newlines) + "\n```\n")
            remaining = remaining[close.upperBound...]
        }
        pieces.append(collapsed(String(remaining)))
        text = pieces.joined()

        let replacements: [(String, String)] = [
            // A line break starts a new paragraph (Markdown would join the lines).
            ("<br\\s*/?>", "\n\n"),
            ("<h1[^>]*>", "\n\n# "), ("<h2[^>]*>", "\n\n## "), ("<h3[^>]*>", "\n\n### "),
            ("<h[4-6][^>]*>", "\n\n#### "), ("</h[1-6]>", "\n\n"),
            ("<li[^>]*>", "\n- "), ("</li>", "\n"),
            ("</?(ul|ol|p|div|section|article|table|tr|blockquote|dl)[^>]*>", "\n\n"),
            ("<hr[^>]*>", "\n\n---\n\n"),
            ("</?(strong|b)(\\s[^>]*)?>", "**"), ("</?(em|i)(\\s[^>]*)?>", "*"), ("</?code[^>]*>", "`"),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        text = convertingLinks(text)
        text = decodeEntities(stripTags(text))
        // Spaces left at line starts by the HTML layout aren't indentation.
        let lines = text.components(separatedBy: "\n").map { line -> String in
            line.hasPrefix("    ") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") ? line.trimmingCharacters(in: .whitespaces) : line
        }
        return markdown(lines.joined(separator: "\n"))
    }

    private static func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func removingElements(_ name: String, from text: String) -> String {
        text.replacingOccurrences(of: "<\(name)[^>]*>[\\s\\S]*?</\(name)>", with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// `<a href="https://…">text</a>` → `[text](https://…)`; other links keep only their text.
    private static func convertingLinks(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: "<a\\s[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>", options: [.caseInsensitive]) else { return text }
        var result = text
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let hrefRange = Range(match.range(at: 1), in: result),
                  let labelRange = Range(match.range(at: 2), in: result) else { continue }
            let href = String(result[hrefRange])
            let label = stripTags(String(result[labelRange])).trimmingCharacters(in: .whitespaces)
            let isWeb = href.lowercased().hasPrefix("https://") || href.lowercased().hasPrefix("http://")
            result.replaceSubrange(whole, with: isWeb && !label.isEmpty ? "[\(label)](\(href))" : label)
        }
        return result
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named: [String: String] = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                                       "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘",
                                       "&rdquo;": "”", "&ldquo;": "“", "&bull;": "•", "&copy;": "©", "&reg;": "®", "&trade;": "™"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let expression = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            for match in expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let whole = Range(match.range, in: result), let kind = Range(match.range(at: 1), in: result),
                      let digits = Range(match.range(at: 2), in: result),
                      let value = UInt32(result[digits], radix: result[kind].isEmpty ? 10 : 16),
                      let scalar = Unicode.Scalar(value) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: Rendering helpers

    /// Inline Markdown as an attributed string; only web links stay links.
    static func attributed(_ markdown: String) -> AttributedString {
        var string = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        for run in string.runs {
            if let link = run.link, !["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                string[run.range].link = nil
            }
        }
        return string
    }
}

/// Renders a `ReleaseNotesDocument`.
struct ReleaseNotesView: View {
    var document: ReleaseNotesDocument
    var font: Font = .callout

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotesDocument.Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(ReleaseNotesDocument.attributed(text))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, isFirst ? 0 : 6)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(ReleaseNotesDocument.attributed(text))
                .font(font)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(depth == 0 ? "•" : "◦").foregroundStyle(.tertiary)
                Text(ReleaseNotesDocument.attributed(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(font)
            .padding(.leading, CGFloat(depth) * 14)
        case .numbered(let text, let number):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").monospacedDigit().foregroundStyle(.tertiary)
                Text(ReleaseNotesDocument.attributed(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(font)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .padding(8)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}
