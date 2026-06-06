import Foundation

enum AudioTextNormalizer {
    static func normalizedSpeechText(from text: String) -> String {
        var output = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return "" }

        output = stripMarkdownTables(from: output)
        output = addHeadingPauses(to: output)
        output = replacing(output, pattern: "(?s)```.*?```", with: " ")
        output = replacing(output, pattern: "`[^`]*`", with: " ")
        output = replacing(output, pattern: "!\\[([^\\]]*)\\]\\([^\\)]*\\)", with: "$1")
        output = replacing(output, pattern: "\\[([^\\]]+)\\]\\([^\\)]*\\)", with: "$1")
        output = replacing(output, pattern: "\\[\\[([^\\]|]+)\\|([^\\]]+)\\]\\]", with: "$2")
        output = replacing(output, pattern: "\\[\\[([^\\]]+)\\]\\]", with: "$1")
        output = replaceURLsWithDomainSpeech(in: output)
        output = replacing(output, pattern: "(?m)^\\s{0,3}#{1,6}\\s*", with: "")
        output = replacing(output, pattern: "(?m)^\\s*([-*+]|\\d+\\.)\\s+", with: "")
        output = output
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "<!--truncate-->", with: " ")
        output = stripEmojiLikeScalars(from: output)
        output = replacing(output, pattern: "(?s)<[^>]*>", with: " ")
        output = replacing(output, pattern: "\\s+", with: " ")

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    static func addHeadingPauses(to markdown: String) -> String {
        markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("#") else {
                    return String(line)
                }

                let heading = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !heading.isEmpty else { return "" }
                return "\n\n\(heading).\n\n"
            }
            .joined(separator: "\n")
    }

    static func stripMarkdownTables(from markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var index = 0

        while index < lines.count {
            if index + 1 < lines.count,
               looksLikeTableHeader(lines[index]),
               isMarkdownTableSeparatorLine(lines[index + 1]) {
                index += 2
                while index < lines.count {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || !trimmed.contains("|") {
                        index -= 1
                        break
                    }
                    index += 1
                }
            } else {
                output.append(lines[index])
            }
            index += 1
        }

        return output.joined(separator: "\n")
    }

    static func looksLikeTableHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.contains("|")
    }

    static func isMarkdownTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("-"), trimmed.contains("|") else {
            return false
        }

        let parts = trimmed.split(separator: "|", omittingEmptySubsequences: false)
        var validColumnCount = 0

        for part in parts {
            let cell = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if cell.isEmpty {
                continue
            }

            guard let regex = try? NSRegularExpression(pattern: "^:?-{3,}:?$") else {
                return false
            }
            let range = NSRange(cell.startIndex..., in: cell)
            guard regex.firstMatch(in: cell, options: [], range: range) != nil else {
                return false
            }
            validColumnCount += 1
        }

        return validColumnCount >= 2
    }

    static func replaceURLsWithDomainSpeech(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)\b(?:https?|ftp)://[^\s<>()]+|\bwww\.[^\s<>()]+"#, options: []) else {
            return text
        }

        return regex.replaceMatches(in: text)
    }

    static func stripEmojiLikeScalars(from text: String) -> String {
        let filtered = text.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .otherSymbol, .modifierSymbol, .surrogate, .privateUse:
                return false
            default:
                return true
            }
        }
        return String(String.UnicodeScalarView(filtered))
    }
}

private extension NSRegularExpression {
    func replaceMatches(in text: String) -> String {
        let matches = self.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }

            let raw = String(result[range])
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}\\\"'"))
            let replacement: String

            if trimmed.isEmpty {
                replacement = " "
            } else {
                let candidate = trimmed.lowercased().hasPrefix("www.") ? "https://\(trimmed)" : trimmed
                if let url = URL(string: candidate), let host = url.host, !host.isEmpty {
                    replacement = " link to \(host.lowercased()) "
                } else {
                    replacement = " link "
                }
            }

            result.replaceSubrange(range, with: replacement)
        }
        return result
    }
}
